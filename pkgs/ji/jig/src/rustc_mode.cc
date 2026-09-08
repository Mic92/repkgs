#include "rustc_mode.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <format>
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
#include "keys.h"
#include "manifest.h"
#include "process.h"
#include "store.h"

namespace jig {

namespace {

namespace fs = std::filesystem;

constexpr unsigned kPermissionBits = 0777;
using std::string_view_literals::operator""sv;

// options whose value is the next token: keep flag and value together in the key
constexpr std::array kTwoTokenOptions{
    "-C"sv,
    "--cfg"sv,
    "--check-cfg"sv,
    "--cap-lints"sv,
    "--edition"sv,
    "--target"sv,
    "--crate-type"sv,
    "-Z"sv,
    "-W"sv,
    "-A"sv,
    "-D"sv,
    "-F"sv,
    "--error-format"sv,
    "--json"sv,
    "--diagnostic-width"sv,
    "--remap-path-prefix"sv,
    "--sysroot"sv,
    "-l"sv,
};

// dep-info: one "output: inputs…" rule per artifact, then "input:" phony rules and "# …" comments
struct DepInfo {
  std::vector<std::string> outputs;
  std::vector<std::string> inputs;
};

auto ParseDepInfo(std::string_view text) -> DepInfo {
  DepInfo info;
  for (const std::string& line : Split(text, '\n')) {
    if (line.starts_with('#')) {
      continue;
    }
    const size_t colon = line.find(": ");
    if (colon == std::string::npos) {
      continue;  // "input:" phony rule (nothing after the colon)
    }
    info.outputs.push_back(line.substr(0, colon));
    if (info.inputs.empty()) {
      info.inputs = ParseDepfile(line);
    }
  }
  return info;
}

// "<name> <octal mode> <size>\n<bytes>" per file. The metadata stem is replaced by "@"
auto PackFiles(std::span<const std::string> paths, std::string_view stem) -> std::string {
  std::string blob;
  for (const std::string& path : paths) {
    const std::optional<std::string> data = ReadFile(path);
    if (!data) {
      continue;
    }
    std::error_code ignored;
    const unsigned mode = static_cast<unsigned>(fs::status(path, ignored).permissions()) & kPermissionBits;
    blob += std::format("{} {:o} {}\n", ReplaceAll(fs::path(path).filename().string(), stem, "@"), mode, data->size());
    blob += *data;
  }
  return blob;
}

auto UnpackFiles(std::string_view blob, const fs::path& dir, std::string_view stem) -> bool {
  while (!blob.empty()) {
    const size_t newline = blob.find('\n');
    if (newline == std::string_view::npos) {
      return false;
    }
    const std::vector<std::string> head = Split(blob.substr(0, newline), ' ');
    if (head.size() != 3) {
      return false;
    }
    constexpr int kOctal = 8;
    const std::optional<std::uint64_t> mode = ParseUint(head.at(1), kOctal);
    const std::optional<std::uint64_t> size = ParseUint(head.at(2));
    if (!mode || !size || *size > blob.size() - (newline + 1)) {
      return false;
    }
    const fs::path out = dir / ReplaceAll(head.at(0), "@", stem);
    if (!WriteFile(out, blob.substr(newline + 1, *size))) {
      return false;
    }
    std::error_code ignored;
    fs::permissions(out, static_cast<fs::perms>(*mode), ignored);
    blob.remove_prefix(newline + 1 + *size);
  }
  return true;
}

// The named long options whose value matters to us. True if `arg` was one (idx advanced past a
// separate value token).
auto TakeNamedOption(std::span<const std::string> args, size_t& idx, RustInvocation& inv) -> bool {
  const std::string& arg = args.at(idx);
  // "--flag value" or "--flag=value"
  const auto take = [&](std::string_view flag) -> std::optional<std::string> {
    if (arg == flag && idx + 1 < args.size()) {
      return args.at(++idx);
    }
    if (arg.size() > flag.size() && arg.starts_with(flag) && arg.at(flag.size()) == '=') {
      return arg.substr(flag.size() + 1);
    }
    return std::nullopt;
  };
  if (auto value = take("--out-dir")) {
    inv.out_dir = *value;
  } else if (auto value = take("--crate-name")) {
    inv.key_args.push_back("--crate-name=" + *value);
    inv.crate_name = *std::move(value);
  } else if (auto value = take("--extern")) {
    if (const size_t equals = value->find('='); equals != std::string::npos) {
      inv.externs.push_back(value->substr(equals + 1));
    }
    inv.key_args.push_back("--extern=" + *value);
  } else if (auto value = take("--emit")) {
    inv.has_dep_info = inv.has_dep_info || value->contains("dep-info");
    inv.key_args.push_back("--emit=" + *value);
  } else if (auto const value = take("-L")) {
    // search dirs: externs are explicit inputs already
  } else {
    return false;
  }
  return true;
}

// -C/-Z/… style options, joined with their value. Metadata hashes only rename outputs
void TakeCodegenOption(std::span<const std::string> args, size_t& idx, RustInvocation& inv) {
  constexpr std::string_view kExtraFilename = "extra-filename=";
  std::string full = args.at(idx);
  if (std::ranges::contains(kTwoTokenOptions, std::string_view(full)) && idx + 1 < args.size()) {
    full += "=" + args.at(++idx);
  }
  if (full.starts_with("-C=incremental=") || full.starts_with("-Cincremental=")) {
    inv.cacheable = false;
  } else if (const size_t pos = full.find(kExtraFilename); pos != std::string::npos && full.starts_with("-C")) {
    inv.extra_filename = full.substr(pos + kExtraFilename.size());
  } else if (!full.starts_with("-C=metadata=") && !full.starts_with("-Cmetadata=")) {
    inv.key_args.push_back(std::move(full));
  }
}

// executables and dylibs are produced by an external linker whose identity and flags we cannot see
auto LinksExternally(const RustInvocation& inv) -> bool {
  const auto crate_type = [&](std::string_view type) -> bool {
    return std::ranges::contains(inv.key_args, std::format("--crate-type={}", type));
  };
  const bool has_type = std::ranges::any_of(
      inv.key_args, [](const std::string& key_arg) -> bool { return key_arg.starts_with("--crate-type="); });
  return !has_type || crate_type("bin") || crate_type("cdylib") || crate_type("dylib") || crate_type("proc-macro");
}

}  // namespace

auto ParseRustInvocation(std::span<const std::string> args) -> RustInvocation {
  RustInvocation inv;
  inv.args.assign(args.begin(), args.end());
  int sources = 0;
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string& arg = args.at(i);
    if (TakeNamedOption(args, i, inv)) {
      continue;
    }
    if (arg == "-o" || arg == "--print" || arg.starts_with("--print=") || arg == "-") {
      inv.cacheable = false;
    } else if (arg.starts_with("-L")) {
      // -Lnative=…: same as the two-token form
    } else if (!arg.starts_with('-') && arg.ends_with(".rs")) {
      inv.source = arg;
      ++sources;
    } else {
      TakeCodegenOption(args, i, inv);
    }
  }
  if (sources != 1 || LinksExternally(inv) || inv.out_dir.empty() || !inv.has_dep_info) {
    inv.cacheable = false;
  }
  return inv;
}

auto RunRustcMode(std::span<const std::string> argv, const std::string& socket_path) -> int {
  const Stopwatch clock;
  // as cargo's RUSTC_WRAPPER argv[1] is the real rustc. Otherwise $JIG_RUSTC names it
  std::string rustc = Env("JIG_RUSTC");
  std::span<const std::string> args = argv.subspan(1);
  if (!args.empty() && args.at(0).ends_with("rustc")) {
    rustc = args.at(0);
    args = args.subspan(1);
  }
  if (rustc.empty()) {
    std::println(stderr, "jig: JIG_RUSTC unset");
    return 1;
  }
  const RustInvocation inv = ParseRustInvocation(args);
  const std::string label = inv.crate_name.empty() ? inv.source : inv.crate_name + inv.extra_filename;

  CacheClient cache;
  std::optional<std::string> source_bytes;
  if (inv.cacheable) {
    source_bytes = ReadFile(inv.source);
  }
  if (!inv.cacheable || !source_bytes || !cache.Connect(socket_path)) {
    const int status = Run(rustc, inv.args, StderrMode::kInherit).status;
    Outcome outcome = Outcome::kPlainNoSocket;
    if (!inv.cacheable) {
      outcome = Outcome::kPlainCompile;
    } else if (!source_bytes) {
      outcome = Outcome::kPlainNoSource;
    }
    LogOutcome(outcome, label, clock, "rs-");
    return status;
  }

  Store& store = Store::Get();
  store.LearnRoots(rustc);
  for (const std::string& arg : inv.key_args) {
    store.LearnRoots(arg);
  }
  Hasher hasher;
  hasher.Field("rustc=" + Store::ToolId(rustc));
  hasher.Field("cwd=" + store.Key(fs::current_path().string()));
  for (const std::string& arg : inv.key_args) {
    hasher.Field(store.Key(arg));
  }
  for (const std::string& rlib : inv.externs) {
    hasher.Field("extern:" + store.InputId(rlib).value_or("?"));
  }
  for (const char* var :
       {"CARGO_PKG_NAME", "CARGO_PKG_VERSION", "CARGO_CFG_TARGET_FEATURE", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS"}) {
    hasher.Field(std::format("{}={}", var, Env(var)));
  }
  hasher.Field(*source_bytes);
  const RequestKey request_key(Tool::kRustc, hasher.Finish());

  if (const std::optional<std::string> manifest = cache.Get(slot::Manifest(request_key))) {
    if (const std::optional<ResultKey> result_key = ValidateManifest(request_key, *manifest)) {
      const std::optional<std::string> blob = cache.Get(slot::Object(*result_key));
      if (blob && UnpackFiles(*blob, inv.out_dir, inv.extra_filename)) {
        std::print(stderr, "{}", cache.Get(slot::Stderr(*result_key)).value_or(""));
        LogOutcome(Outcome::kHit, label, clock, "rs-");
        return 0;
      }
    }
  }

  const RunResult run = Run(rustc, inv.args, StderrMode::kCapture);
  std::print(stderr, "{}", run.stderr_text);
  if (run.status != 0) {
    LogOutcome(Outcome::kMissFail, label, clock, "rs-");
    return run.status;
  }
  // with cargo the dep-info is exactly <out-dir>/<crate><extra>.d. Scanning would race sibling variants
  const std::optional<std::string> dep_text =
      ReadFile(fs::path(inv.out_dir) / (inv.crate_name + inv.extra_filename + ".d"));
  if (!dep_text) {
    LogOutcome(Outcome::kMissUnstored, label, clock, "rs-");
    return 0;
  }
  const DepInfo info = ParseDepInfo(*dep_text);
  // "# env-dep:" lines (env!() inputs) are not tracked yet. CARGO_PKG_* are in k1
  const Manifest manifest = BuildManifest(request_key, info.inputs, inv.source);
  cache.Put(slot::Manifest(request_key), manifest.text);
  cache.Put(slot::Object(manifest.result_key), PackFiles(info.outputs, inv.extra_filename));
  cache.Put(slot::Stderr(manifest.result_key), run.stderr_text);
  LogOutcome(Outcome::kMissStored, label, clock, "rs-");
  return 0;
}

}  // namespace jig
