#include "cc_mode.h"

#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdio>
#include <expected>
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

auto HasLinkerSideOutput(std::string_view arg) -> bool {
  static constexpr std::array kMarkers{
      "-Map"sv,    "--print-map"sv, ",-M,"sv,      "--dependency-file"sv,   "--out-implib"sv,
      "--trace"sv, ",-t,"sv,        "--verbose"sv, "--print-gc-sections"sv, "--stats"sv,
  };
  return (arg.starts_with("-Wl,") || arg.starts_with("-Xlinker")) &&
         (std::ranges::any_of(kMarkers, [&](std::string_view marker) -> bool { return arg.contains(marker); }) ||
          arg.ends_with(",-M") || arg.ends_with(",-t"));
}

// Options after which caching is pointless: preprocess/asm/dependency-only/query runs.
auto IsNoOutputOption(std::string_view arg) -> bool {
  static constexpr std::array kExact{
      "-M"sv, "-MM"sv,       "-"sv,    "-v"sv,  //
      "-V"sv, "--version"sv, "-###"sv, "-fsyntax-only"sv,
  };
  return std::ranges::contains(kExact, arg) || arg.starts_with("-print") || arg.starts_with("--print") ||
         arg.starts_with("-dump");
}

// `primary`: the source bytes, or for a link the InputId of every object/archive argument
auto ComputeRequestKey(const std::string& compiler, const Invocation& inv, std::string_view primary) -> RequestKey {
  const Store& store = Store::Get();
  const bool links = inv.link_one || inv.link;
  Hasher hasher;
  hasher.Field("cc=" + store.ToolId(compiler));
  // cwd: relative -I/-include and __FILE__ depend on it. Inside the sandbox it is stable
  hasher.Field("cwd=" + store.Key(fs::current_path().string()));
  std::string_view mode = "mode=compile";
  if (inv.link) {
    mode = "mode=link";
  } else if (inv.link_one) {
    mode = "mode=link-one";
  }
  hasher.Field(mode);
  if (links) {
    hasher.Field("LIBRARY_PATH=" + store.MaskForReplay(Env("LIBRARY_PATH")));
  }
  // never masked: paths the binary embeds verbatim (PT_INTERP, RUNPATH), and anything naming our
  // own output prefix (-DENGINESDIR="$out/lib/..."), which ends up in .rodata
  const std::string out = Env("out");
  for (const std::string& arg : inv.key_args) {
    const bool embedded =
        (links && (arg.contains("dynamic-linker") || arg.contains("rpath"))) || (!out.empty() && arg.contains(out));
    hasher.Field(embedded ? arg : store.Key(arg));
  }
  hasher.Field(primary);
  return {Tool::kCc, hasher.Finish()};
}

// what the request key hashes besides the arguments. nullopt = an input is unreadable
auto PrimaryIdentity(const Invocation& inv) -> std::optional<std::string> {
  std::string ids;
  if (!inv.link) {
    std::optional<std::string> text = ReadFile(inv.source);
    // a PCH is consumed like a header but is a binary of this build tree, tied to the absolute
    // paths it was made under: its bytes are part of what the TU is
    for (const std::string& pch : inv.pch) {
      const std::optional<std::string> pch_id = Store::Get().InputId(pch);
      if (!text || !pch_id) {
        return std::nullopt;
      }
      *text += "\npch=" + *pch_id;
    }
    return text;
  }
  for (const std::string& input : inv.inputs) {
    const std::optional<std::string> input_id = Store::Get().InputId(input);
    if (!input_id) {
      return std::nullopt;
    }
    ids += input + "=" + *input_id + "\n";
  }
  return ids;
}

// Everything a hit has to reproduce. nullopt = not usable, compile for real.
struct CachedResult {
  int status = 0;
  std::optional<std::string> object;
  std::optional<std::string> depfile;
  std::string stderr_text;
};

// the error is why there is nothing to replay (FindResult's, or "object-gone")
auto Lookup(CacheClient& cache, const RequestKey& request_key, const Invocation& inv)
    -> std::expected<CachedResult, std::string> {
  const std::expected<ResultKey, std::string> result_key = FindResult(cache, request_key);
  if (!result_key) {
    return std::unexpected(result_key.error());
  }
  // everything a replay might need in one pipelined exchange. Unused answers are cheap MISSes
  const std::vector<std::string> keys{
      slot::ExitStatus(*result_key),
      slot::Object(*result_key),
      slot::Depfile(*result_key),
      slot::Stderr(*result_key),
  };
  std::vector<std::optional<std::string>> got = cache.GetMany(keys);
  std::optional<std::string>& status = got.at(0);
  std::optional<std::string>& object = got.at(1);
  std::optional<std::string>& depfile = got.at(2);
  std::optional<std::string>& stderr_text = got.at(3);
  CachedResult result{};
  // an exit status slot exists only for cached failures. Link failures are never cached (see header)
  if (!inv.link_one && !inv.link && status.has_value()) {
    result.status = static_cast<int>(ParseUint(*status).value_or(1));
  }
  if (result.status == 0) {
    // depfile options are not in the key, so an entry stored by a run without -MD lacks one
    if (!object || (inv.wants_depfile && !depfile)) {
      return std::unexpected("object-gone");
    }
    result.object = std::move(object);
    result.depfile = inv.wants_depfile ? std::move(depfile) : std::nullopt;
  }
  result.stderr_text = std::move(stderr_text).value_or("");
  return result;
}

// -E without -o: the text the caller expects on stdout sits in (or was replayed instead of) a temp file
void ForwardStdout(const Invocation& inv, const std::optional<std::string>& text) {
  if (!inv.to_stdout) {
    return;
  }
  std::error_code ignored;
  fs::remove(inv.output, ignored);
  if (text) {
    std::print("{}", *text);
    std::fflush(stdout);
  }
}

auto Replay(const CachedResult& result, const Invocation& inv) -> int {
  if (inv.to_stdout) {
    ForwardStdout(inv, result.object);
  } else if (result.object) {
    WriteFile(inv.output, *result.object);
    if (inv.link_one || inv.link) {
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

// The real compiler run plus what it read: the preprocessor depfile (none for a pure link, then
// ""), and for links lld's dependency file minus the driver's temp object. nullopt = not learnable
struct Observed {
  RunResult run;
  std::optional<std::string> dep_text;
  std::optional<std::string> link_dep_text;
  std::vector<std::string> inputs;
};

auto RunObserved(CacheClient& cache, const std::string& compiler, const Invocation& inv) -> Observed {
  std::vector<std::string> args = inv.args;
  const fs::path out_dir = inv.output.has_parent_path() ? inv.output.parent_path() : fs::path(".");
  const std::string tmp_base = (out_dir / std::format(".jig{}", ::getpid())).string();
  const bool links = inv.link_one || inv.link;
  const bool own_depfile = !inv.wants_depfile && !inv.link;
  const fs::path depfile = own_depfile ? fs::path(tmp_base + ".d") : inv.depfile;
  const fs::path link_depfile = tmp_base + ".link.d";
  if (own_depfile) {
    args.insert(args.end(), {"-MD", "-MF", depfile.string()});
  }
  if (inv.to_stdout) {
    args.insert(args.end(), {"-o", inv.output.string()});
  }
  if (links) {
    args.push_back("-Wl,--dependency-file=" + link_depfile.string());
  }

  Observed obs;
  {
    const Slot slot(cache, "");
    obs.run = Run(compiler, args, StderrMode::kCapture);
  }
  std::print(stderr, "{}", obs.run.stderr_text);
  obs.dep_text = inv.link ? std::optional<std::string>("") : ReadFile(depfile);
  obs.link_dep_text = links ? ReadFile(link_depfile) : std::nullopt;
  std::error_code ignored;
  if (own_depfile) {
    fs::remove(depfile, ignored);
  }
  fs::remove(link_depfile, ignored);
  if (obs.dep_text) {
    obs.inputs = ParseDepfile(*obs.dep_text);
  }
  if (obs.link_dep_text) {
    const std::string tmp = fs::temp_directory_path(ignored).string() + "/";
    for (std::string& input : ParseDepfile(*obs.link_dep_text)) {
      if (!input.starts_with(tmp)) {
        obs.inputs.push_back(std::move(input));
      }
    }
  }
  return obs;
}

// Compile for real, learning the inputs. Store what is replayable. Returns the compiler's status.
auto CompileAndStore(CacheClient& cache, const std::string& compiler, const RequestKey& request_key,
                     const Invocation& inv, const std::string& why, const Stopwatch& clock) -> int {
  const Store& store = Store::Get();
  const std::string subject = inv.source + " " + why;
  const bool links = inv.link_one || inv.link;
  const auto [run, dep_text, link_dep_text, inputs] = RunObserved(cache, compiler, inv);

  if (run.status != 0) {
    ForwardStdout(inv, std::nullopt);
    // replayable only if every input is known. A missing header or any link error depends on
    // something absent that a later build may provide
    if (!dep_text || links || run.stderr_text.contains("file not found")) {
      LogOutcome("cc", Outcome::kMissFail, subject, clock);
      return run.status;
    }
    const Manifest manifest = BuildManifest(cache, request_key, inputs, inv.source);
    cache.Put(slot::Manifest(request_key), manifest.text);
    cache.Put(slot::ExitStatus(manifest.result_key), std::to_string(run.status));
    cache.Put(slot::Stderr(manifest.result_key), run.stderr_text);
    LogOutcome("cc", Outcome::kMissStoredFail, subject, clock);
    return run.status;
  }

  const std::optional<std::string> object = ReadFile(inv.output);
  ForwardStdout(inv, object);
  if (!dep_text || !object || (links && !link_dep_text)) {
    LogOutcome("cc", Outcome::kMissUnstored, subject, clock);
    return 0;
  }
  const Manifest manifest = BuildManifest(cache, request_key, inputs, inv.source);
  cache.Put(slot::Manifest(request_key), manifest.text);
  cache.Put(slot::Object(manifest.result_key), *object);
  cache.Put(slot::Stderr(manifest.result_key), run.stderr_text);
  // content mode: the depfile names this build's store paths. The next build must see its own
  if (inv.wants_depfile) {
    cache.Put(slot::Depfile(manifest.result_key), store.MaskForReplay(*dep_text));
  }
  LogOutcome("cc", Outcome::kMissStored, subject, clock);
  return 0;
}

void LogUncached(Outcome outcome, std::span<const std::string> user_args) {
  // JIG_LOG_ARGS=<file>: the uncached command lines as the build system gave them
  const std::string path = Env("JIG_LOG_ARGS");
  if (path.empty()) {
    return;
  }
  if (outcome == Outcome::kPlainQuery) {
    return;  // nothing to teach the cache about `cc -v`
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

// -include-pch <file>, also spelt -Xclang -include-pch -Xclang <file> (cmake): the file is the next
// non-Xclang word. Stays in the key and is remembered so its bytes enter the primary identity.
auto TakePchOption(std::span<const std::string> args, size_t& idx, Invocation& inv) -> bool {
  if (args.at(idx) != "-include-pch") {
    return false;
  }
  inv.key_args.push_back(args.at(idx));
  while (idx + 1 < args.size() && args.at(idx + 1) == "-Xclang") {
    inv.key_args.push_back(args.at(++idx));
  }
  if (idx + 1 < args.size()) {
    inv.key_args.push_back(args.at(++idx));
    inv.pch.push_back(args.at(idx));
  }
  return true;
}

}  // namespace

namespace {

// compile / link-one (configure probe) / link, default output and depfile names. `stop` is the
// last of -c/-S/-E given (0 if none)
void Classify(Invocation& inv, int sources, bool objects, char stop) {
  if (inv.compile_only) {
    inv.cacheable = inv.cacheable && sources == 1;
    // `-E -dM`, `-E - </dev/null`, `-E -x c /dev/null`: build systems asking for predefined macros
    inv.query = inv.query || (stop == 'E' && (sources == 0 || inv.source == "/dev/null"));
    if (stop == 'E' && (inv.output.empty() || inv.output == "-")) {
      // the text goes to our stdout; the compiler writes a temp file we replay from
      inv.to_stdout = true;
      inv.output = fs::path(Env("TMPDIR", "/tmp")) / std::format("jig{}.i", ::getpid());
    } else if (inv.output.empty()) {
      inv.output = fs::path(inv.source).stem().string() + (stop == 'S' ? ".s" : ".o");
    }
  } else {
    inv.link_one = !objects && sources == 1;
    inv.link = objects && sources == 0 && !inv.inputs.empty();
    inv.cacheable = inv.cacheable && (inv.link_one || inv.link);
    if (inv.output.empty()) {
      inv.output = "a.out";
    }
    if (inv.link) {
      inv.source = inv.output.filename().string();  // log label
    }
  }
  if (inv.wants_depfile && inv.depfile.empty()) {
    inv.depfile = fs::path(inv.output).replace_extension(".d");  // -MD without -MF
  }
}

}  // namespace

auto ParseInvocation(std::span<const std::string> args) -> Invocation {
  Invocation inv;
  inv.args.assign(args.begin(), args.end());
  bool objects = false;
  int sources = 0;
  char stop = 0;
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string& arg = args.at(i);
    if (TakeDepfileOption(args, i, inv)) {
      continue;
    }
    if (arg == "-c" || arg == "-S" || arg == "-E") {
      inv.compile_only = true;
      stop = arg.at(1);
      inv.key_args.push_back(arg);
    } else if (arg == "-o" && i + 1 < args.size()) {
      inv.output = args.at(++i);
    } else if (arg.starts_with("-o") && arg.size() > 2) {
      inv.output = arg.substr(2);
    } else if (IsNoOutputOption(arg)) {
      inv.cacheable = false;
      inv.query = true;
    } else if (IsSourceFile(arg)) {
      inv.source = arg;
      ++sources;
    } else if (TakePchOption(args, i, inv)) {
      continue;
    } else if (IsObjectInput(arg)) {
      objects = true;
      inv.inputs.push_back(arg);
      inv.key_args.push_back(arg);
    } else {
      objects = objects || arg == "-shared" || arg == "-r";
      // -Wl,@rsp hides inputs from us (a bare @rsp was expanded on entry). -Map and friends write
      // or print a second output. A PCH records the
      // absolute path and size of every header it read and clang re-validates them on load, so
      // one produced under another build's sysroot path is rejected: never replay those.
      inv.cacheable = inv.cacheable && !arg.starts_with('@') && !arg.contains(",@") && !HasLinkerSideOutput(arg) &&
                      !arg.ends_with("-header");
      inv.key_args.push_back(arg);
    }
  }
  inv.cacheable = inv.cacheable && inv.output.extension() != ".pch" && inv.output.extension() != ".gch";
  Classify(inv, sources, objects, stop);
  return inv;
}

auto RunCcMode(std::string_view argv0, std::span<const std::string> raw_args, const std::string& socket_path) -> int {
  const Stopwatch clock;
  // ghc puts the whole link behind one @rsp, -shared and -o included: classify, key and link
  // policy (no crt_interp.o into a shared object) all need the words themselves
  const std::vector<std::string> user_args = ExpandResponseFiles(raw_args);
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
  std::optional<std::string> primary;
  if (inv.cacheable) {
    primary = PrimaryIdentity(inv);
  }
  if (!inv.cacheable || !primary || !cache.Connect(socket_path)) {
    int status = 0;
    {
      // -print-*, --version and friends are no work worth a slot (and glibc runs 600 of them)
      std::optional<Slot> slot;
      if (!inv.source.empty() || !inv.inputs.empty()) {
        slot.emplace(cache, socket_path);
      }
      status = Run(conf->cc, inv.args, StderrMode::kInherit).status;
    }
    Outcome outcome = Outcome::kPlainNoSocket;
    if (inv.query) {
      outcome = Outcome::kPlainQuery;
    } else if (!inv.cacheable) {
      outcome = inv.compile_only ? Outcome::kPlainCompile : Outcome::kPlainLink;
    } else if (!primary) {
      outcome = Outcome::kPlainNoSource;
    }
    LogOutcome("cc", outcome, inv.source, clock);
    LogUncached(outcome, user_args);
    return status;
  }

  const RequestKey request_key = ComputeRequestKey(conf->cc, inv, *primary);
  const std::expected<CachedResult, std::string> hit = Lookup(cache, request_key, inv);
  if (hit) {
    const int status = Replay(*hit, inv);
    LogOutcome("cc", status == 0 ? Outcome::kHit : Outcome::kHitFail, inv.source, clock);
    return status;
  }
  return CompileAndStore(cache, conf->cc, request_key, inv, hit.error(), clock);
}

}  // namespace jig
