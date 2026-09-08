#include "cc_mode.h"

#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <filesystem>
#include <format>
#include <fstream>
#include <ios>
#include <optional>
#include <print>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "base.h"
#include "cache_client.h"
#include "driver.h"
#include "keys.h"
#include "manifest.h"
#include "process.h"
#include "store.h"

namespace jig {

namespace {

namespace fs = std::filesystem;
using std::string_view_literals::operator""sv;

auto HasSuffix(std::string_view arg, std::span<const std::string_view> suffixes) -> bool {
  return std::ranges::any_of(
      suffixes, [&](std::string_view suffix) -> bool { return arg.size() > suffix.size() && arg.ends_with(suffix); });
}

auto IsSourceFile(std::string_view arg) -> bool {
  static constexpr std::array kExts{
      ".c"sv, ".cc"sv, ".cpp"sv, ".cxx"sv, ".c++"sv,  //
      ".C"sv, ".S"sv,  ".s"sv,   ".sx"sv,  ".m"sv,
  };
  return !arg.starts_with('-') && HasSuffix(arg, kExts);
}

auto IsObjectInput(std::string_view arg) -> bool {
  static constexpr std::array kExts{".o"sv, ".os"sv, ".lo"sv, ".a"sv, ".so"sv, ".obj"sv};
  return !arg.starts_with('-') && (HasSuffix(arg, kExts) || arg.contains(".so."));
}

// Options after which caching is pointless: preprocess/asm/dependency-only/query runs.
auto IsNoOutputOption(std::string_view arg) -> bool {
  static constexpr std::array kExact{
      "-M"sv, "-MM"sv, "-E"sv,        "-S"sv,   "-"sv,  //
      "-v"sv, "-V"sv,  "--version"sv, "-###"sv, "-fsyntax-only"sv,
  };
  return std::ranges::contains(kExact, arg) || arg.starts_with("-print") || arg.starts_with("--print") ||
         arg.starts_with("-dump");
}

auto ComputeRequestKey(const std::string& compiler, const Invocation& inv, std::string_view source_bytes)
    -> RequestKey {
  const Store& store = Store::Get();
  Hasher hasher;
  hasher.Field("cc=" + Store::ToolId(compiler));
  // cwd: relative -I/-include and __FILE__ depend on it. Inside the sandbox it is stable
  hasher.Field("cwd=" + store.Key(fs::current_path().string()));
  hasher.Field(inv.link_one ? "mode=link" : "mode=compile");
  if (inv.link_one) {
    hasher.Field("LIBRARY_PATH=" + store.MaskForReplay(Env("LIBRARY_PATH")));
  }
  for (const std::string& arg : inv.key_args) {
    // paths the executable embeds verbatim (PT_INTERP, RUNPATH) are never masked: a probe binary
    // built against another toolchain instance would name a dynamic linker that may not exist here
    const bool embedded = inv.link_one && (arg.contains("dynamic-linker") || arg.contains("rpath"));
    hasher.Field(embedded ? arg : store.Key(arg));
  }
  hasher.Field(source_bytes);
  return {Tool::kCc, hasher.Finish()};
}

// Everything a hit has to reproduce. nullopt = not usable, compile for real.
struct CachedResult {
  int status = 0;
  std::optional<std::string> object;
  std::optional<std::string> depfile;
  std::string stderr_text;
};

auto Lookup(CacheClient& cache, const RequestKey& request_key, const Invocation& inv) -> std::optional<CachedResult> {
  const std::optional<std::string> manifest = cache.Get(slot::Manifest(request_key));
  if (!manifest) {
    return std::nullopt;
  }
  const std::optional<ResultKey> result_key = ValidateManifest(request_key, *manifest);
  if (!result_key) {
    return std::nullopt;
  }
  CachedResult result{};
  // an exit status slot exists only for cached failures. Link failures are never cached (see header)
  if (!inv.link_one) {
    if (const std::optional<std::string> status = cache.Get(slot::ExitStatus(*result_key))) {
      result.status = static_cast<int>(ParseUint(*status).value_or(1));
    }
  }
  if (result.status == 0) {
    result.object = cache.Get(slot::Object(*result_key));
    if (!result.object) {
      return std::nullopt;
    }
    if (inv.wants_depfile) {
      // depfile options are not in the key, so an entry stored by a run without -MD lacks one
      result.depfile = cache.Get(slot::Depfile(*result_key));
      if (!result.depfile) {
        return std::nullopt;
      }
    }
  }
  result.stderr_text = cache.Get(slot::Stderr(*result_key)).value_or("");
  return result;
}

auto Replay(const CachedResult& result, const Invocation& inv) -> int {
  if (result.object) {
    WriteFile(inv.output, *result.object);
    if (inv.link_one) {
      std::error_code ignored;
      fs::permissions(inv.output, fs::perms::owner_exec | fs::perms::group_exec | fs::perms::others_exec,
                      fs::perm_options::add, ignored);
    }
  }
  if (result.depfile) {
    WriteFile(inv.depfile, Store::Get().ResolveAll(*result.depfile));
  }
  std::print(stderr, "{}", result.stderr_text);
  return result.status;
}

// Compile for real, learning the inputs. Store what is replayable. Returns the compiler's status.
auto CompileAndStore(CacheClient& cache, const std::string& compiler, const RequestKey& request_key,
                     const Invocation& inv, const Stopwatch& clock) -> int {
  const Store& store = Store::Get();
  std::vector<std::string> real_args = inv.args;
  const fs::path out_dir = inv.output.has_parent_path() ? inv.output.parent_path() : fs::path(".");
  const std::string tmp_base = (out_dir / std::format(".jig{}", ::getpid())).string();
  fs::path depfile = inv.depfile;
  if (!inv.wants_depfile) {
    depfile = tmp_base + ".d";
    real_args.insert(real_args.end(), {"-MD", "-MF", depfile.string()});
  }
  const fs::path link_depfile = tmp_base + ".link.d";
  if (inv.link_one) {
    real_args.push_back("-Wl,--dependency-file=" + link_depfile.string());
  }

  const RunResult run = Run(compiler, real_args, StderrMode::kCapture);
  std::print(stderr, "{}", run.stderr_text);
  const std::optional<std::string> dep_text = ReadFile(depfile);
  const std::optional<std::string> link_dep_text = inv.link_one ? ReadFile(link_depfile) : std::nullopt;
  std::error_code ignored;
  if (!inv.wants_depfile) {
    fs::remove(depfile, ignored);
  }
  if (inv.link_one) {
    fs::remove(link_depfile, ignored);
  }

  std::vector<std::string> inputs = dep_text ? ParseDepfile(*dep_text) : std::vector<std::string>{};
  if (link_dep_text) {
    const std::string tmp = fs::temp_directory_path(ignored).string() + "/";  // the driver's intermediate object
    for (std::string& input : ParseDepfile(*link_dep_text)) {
      if (!input.starts_with(tmp)) {
        inputs.push_back(std::move(input));
      }
    }
  }

  if (run.status != 0) {
    // replayable only if every input is known. A missing header or any link error depends on
    // something absent that a later build may provide
    if (!dep_text || inv.link_one || run.stderr_text.contains("file not found")) {
      LogOutcome(Outcome::kMissFail, inv.source, clock);
      return run.status;
    }
    const Manifest manifest = BuildManifest(request_key, inputs, inv.source);
    cache.Put(slot::Manifest(request_key), manifest.text);
    cache.Put(slot::ExitStatus(manifest.result_key), std::to_string(run.status));
    cache.Put(slot::Stderr(manifest.result_key), run.stderr_text);
    LogOutcome(Outcome::kMissStoredFail, inv.source, clock);
    return run.status;
  }

  const std::optional<std::string> object = ReadFile(inv.output);
  if (!dep_text || !object || (inv.link_one && !link_dep_text)) {
    LogOutcome(Outcome::kMissUnstored, inv.source, clock);
    return 0;
  }
  const Manifest manifest = BuildManifest(request_key, inputs, inv.source);
  cache.Put(slot::Manifest(request_key), manifest.text);
  cache.Put(slot::Object(manifest.result_key), *object);
  cache.Put(slot::Stderr(manifest.result_key), run.stderr_text);
  // content mode: the depfile names this build's store paths. The next build must see its own
  if (inv.wants_depfile) {
    cache.Put(slot::Depfile(manifest.result_key), store.MaskForReplay(*dep_text));
  }
  LogOutcome(Outcome::kMissStored, inv.source, clock);
  return 0;
}

void LogUncached(Outcome outcome, std::span<const std::string> user_args) {
  // JIG_LOG_ARGS=<file>: the uncached command lines as the build system gave them
  const std::string path = Env("JIG_LOG_ARGS");
  if (path.empty()) {
    return;
  }
  std::ofstream out(path, std::ios::app);
  out << OutcomeName(outcome) << '\t' << Join(user_args, " ") << '\n';
}

}  // namespace

namespace {

// Depfile options stay out of the key (an entry serves runs with and without -MD). True if `arg`
// (and possibly the next one) was one. Advances idx past a consumed value.
auto TakeDepfileOption(std::span<const std::string> args, size_t& idx, Invocation& inv) -> bool {
  const std::string& arg = args.at(idx);
  const bool has_next = idx + 1 < args.size();
  if (arg == "-MF" && has_next) {
    inv.depfile = args.at(++idx);
  } else if ((arg == "-MT" || arg == "-MQ") && has_next) {
    ++idx;
  } else if (arg.starts_with("-Wp,-MD,") || arg.starts_with("-Wp,-MMD,")) {
    // kbuild's spelling. A driver-level -MD next to it confuses clang, so it counts as ours
    inv.depfile = arg.substr(arg.find(',', std::string_view("-Wp,-").size()) + 1);
  } else if (arg != "-MD" && arg != "-MMD" && arg != "-MP") {
    return false;
  }
  inv.wants_depfile = true;
  return true;
}

}  // namespace

auto ParseInvocation(std::span<const std::string> args) -> Invocation {
  Invocation inv;
  inv.args.assign(args.begin(), args.end());
  bool objects = false;
  int sources = 0;
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string& arg = args.at(i);
    if (TakeDepfileOption(args, i, inv)) {
      continue;
    }
    if (arg == "-c") {
      inv.compile_only = true;
    } else if (arg == "-o" && i + 1 < args.size()) {
      inv.output = args.at(++i);
    } else if (arg.starts_with("-o") && arg.size() > 2) {
      inv.output = arg.substr(2);
    } else if (IsNoOutputOption(arg)) {
      inv.cacheable = false;
    } else if (IsSourceFile(arg)) {
      inv.source = arg;
      ++sources;
    } else {
      objects = objects || IsObjectInput(arg) || arg == "-shared" || arg == "-r";
      inv.key_args.push_back(arg);
    }
  }
  if (sources != 1) {
    inv.cacheable = false;  // none, or several translation units in one call
  }
  if (inv.compile_only) {
    if (inv.output.empty()) {
      inv.output = fs::path(inv.source).stem().string() + ".o";  // compiler default
    }
  } else {
    // a real link (objects, archives, -shared) is the linker's job. One source straight to an
    // executable is a configure/cmake probe and cached like a compile
    inv.link_one = !objects;
    inv.cacheable = inv.cacheable && !objects;
    if (inv.output.empty()) {
      inv.output = "a.out";
    }
  }
  if (inv.wants_depfile && inv.depfile.empty()) {
    inv.depfile = fs::path(inv.output).replace_extension(".d");  // compiler default for -MD without -MF
  }
  return inv;
}

auto RunCcMode(std::string_view argv0, std::span<const std::string> user_args, const std::string& socket_path) -> int {
  const Stopwatch clock;
  const std::optional<DriverConf> conf = LoadDriverConf();
  if (!conf) {
    std::println(stderr, "jig: no etc/jig.conf next to the binary and JIG_CC unset");
    return 1;
  }
  const Language lang = fs::path(argv0).filename().string().contains("++") ? Language::kCxx : Language::kC;

  // classify on what the build system said. The conf's injected flags (crt_interp.o, rpaths) are
  // part of the key but must not make a configure probe look like a real link
  Invocation inv = ParseInvocation(user_args);
  if (conf->present) {
    inv.args = BuildDriverArgs(*conf, lang, user_args);
    for (const std::string& arg : inv.args) {
      if (!std::ranges::contains(user_args, arg)) {
        inv.key_args.push_back(arg);
      }
    }
  }

  CacheClient cache;
  std::optional<std::string> source_bytes;
  if (inv.cacheable) {
    source_bytes = ReadFile(inv.source);
  }
  if (!inv.cacheable || !source_bytes || !cache.Connect(socket_path)) {
    const int status = Run(conf->cc, inv.args, StderrMode::kInherit).status;
    Outcome outcome = Outcome::kPlainNoSocket;
    if (!inv.cacheable) {
      outcome = inv.compile_only ? Outcome::kPlainCompile : Outcome::kPlainLink;
    } else if (!source_bytes) {
      outcome = Outcome::kPlainNoSource;
    }
    LogOutcome(outcome, inv.source, clock);
    LogUncached(outcome, user_args);
    return status;
  }

  Store& store = Store::Get();
  store.LearnRoots(conf->cc);
  store.LearnRoots(fs::current_path().string());
  store.LearnRoots(Env("JIG_STORE_ROOTS"));
  for (const std::string& arg : inv.key_args) {
    store.LearnRoots(arg);
  }

  const RequestKey request_key = ComputeRequestKey(conf->cc, inv, *source_bytes);
  if (const std::optional<CachedResult> hit = Lookup(cache, request_key, inv)) {
    const int status = Replay(*hit, inv);
    LogOutcome(status == 0 ? Outcome::kHit : Outcome::kHitFail, inv.source, clock);
    return status;
  }
  return CompileAndStore(cache, conf->cc, request_key, inv, clock);
}

}  // namespace jig
