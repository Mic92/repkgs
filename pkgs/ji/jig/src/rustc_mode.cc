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

}  // namespace

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
      // relative to rustc's cwd (cargo runs it from the workspace root): absolute, so the
      // manifest can find, hash and later re-check them
      for (const std::string& input : ParseDepfile(line)) {
        info.inputs.push_back(fs::absolute(input).lexically_normal().string());
      }
    }
  }
  return info;
}

namespace {

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
  } else if (auto value = take("-L")) {
    // rlib externs are explicit inputs already. The dirs matter for native -l when rustc links
    const size_t kind = value->find('=');
    inv.lib_dirs.push_back(kind == std::string::npos ? *value : value->substr(kind + 1));
  } else {
    return false;
  }
  return true;
}

// -C/-Z/… style options, joined with their value ("-C" "opt=x" and "-Copt=x" both become
// "-C=opt=x"). Metadata hashes only rename outputs, incremental state is not an input we see
void TakeCodegenOption(std::span<const std::string> args, size_t& idx, RustInvocation& inv) {
  std::string full = args.at(idx);
  if (std::ranges::contains(kTwoTokenOptions, std::string_view(full)) && idx + 1 < args.size()) {
    full += "=" + args.at(++idx);
  } else if (full.starts_with("-C") && !full.starts_with("-C=")) {
    full.insert(2, "=");
  }
  if (full.starts_with("-C=incremental=")) {
    inv.cacheable = false;
  } else if (full.starts_with("-C=extra-filename=")) {
    inv.extra_filename = full.substr(std::string_view("-C=extra-filename=").size());
  } else if (!full.starts_with("-C=metadata=")) {
    if (full.starts_with("-C=linker=")) {
      inv.linker = full.substr(std::string_view("-C=linker=").size());
    } else if (full.starts_with("-l=")) {
      inv.native_libs.push_back(full.substr(full.rfind('=') + 1));  // -l [KIND[:MODIFIERS]=]NAME
    }
    inv.links = inv.links || full == "--crate-type=bin" || full == "--crate-type=proc-macro" ||
                full == "--crate-type=cdylib" || full == "--crate-type=dylib";
    inv.has_crate_type = inv.has_crate_type || full.starts_with("--crate-type=");
    inv.key_args.push_back(std::move(full));
  }
}

// first `name` on PATH (name itself if it has a directory part or is not found)
auto OnPath(const std::string& name) -> std::string {
  if (!name.contains('/')) {
    for (const std::string& dir : Split(Env("PATH"), ':')) {
      std::error_code ignored;
      if (fs::exists(fs::path(dir) / name, ignored)) {
        return (fs::path(dir) / name).string();
      }
    }
  }
  return name;
}

auto RealPath(const std::string& path) -> std::string {
  std::error_code error;
  const fs::path real = fs::canonical(path, error);
  return error ? path : real.string();
}

// What a linking rustc (bin, proc-macro, cdylib, dylib) reads besides its rlib externs: the
// linker (-C linker= or cc from PATH), and for each native -l the file it resolves to in a
// non-store -L dir (target/build/*/out, written by a build script). Store -L dirs are covered
// by their masked path in key_args. Not the whole dir: target/debug/deps is on -L too and holds
// whatever other crates finished first.
// A linked ELF embeds PT_INTERP, RUNPATH and libstd's location as absolute store paths, so
// unlike an rlib it is only right for these exact linker and rustc paths: hashed unmasked
void HashLinkInputs(Hasher& hasher, const RustInvocation& inv, const Store& store, const std::string& rustc) {
  const std::string linker = OnPath(inv.linker.empty() ? "cc" : inv.linker);
  hasher.Field("linker=" + store.ToolId(linker));
  hasher.Field("linker-path=" + RealPath(fs::path(linker).parent_path().string()));
  hasher.Field("rustc-path=" + RealPath(fs::path(rustc).parent_path().string()));
  for (const std::string& lib : inv.native_libs) {
    for (const std::string& dir : inv.lib_dirs) {
      if (store.IsStorePath(dir)) {
        continue;
      }
      for (const std::string& file : {std::format("lib{}.a", lib), std::format("lib{}.so", lib)}) {
        if (const std::optional<std::string> identity = store.InputId((fs::path(dir) / file).string())) {
          hasher.Field(std::format("native:{}={}", file, *identity));
        }
      }
    }
  }
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
    if (arg == "--print" || arg.starts_with("--print=") || arg == "-" || arg == "-vV" || arg == "--version") {
      inv.query = true;
    } else if (arg == "-o") {
      inv.cacheable = false;
    } else if (!arg.starts_with('-') && arg.ends_with(".rs")) {
      inv.source = arg;
      ++sources;
    } else {
      TakeCodegenOption(args, i, inv);
    }
  }
  inv.links = inv.links || !inv.has_crate_type;  // no --crate-type means bin
  if (inv.query || sources != 1 || inv.out_dir.empty() || !inv.has_dep_info) {
    inv.cacheable = false;
  }
  return inv;
}

// cargo's RUSTC_WRAPPER: args = [rustc, rustc args...]
auto RunRustcMode(std::span<const std::string> args, const std::string& socket_path) -> int {
  const Stopwatch clock;
  if (args.empty()) {
    std::println(stderr, "rustcwrap: usage: rustcwrap <rustc> args...");
    return 1;
  }
  const std::string& rustc = args.front();
  args = args.subspan(1);
  const RustInvocation inv = ParseRustInvocation(args);
  const std::string label = inv.crate_name.empty() ? inv.source : inv.crate_name + inv.extra_filename;

  CacheClient cache;
  std::optional<std::string> source_bytes;
  if (inv.cacheable) {
    source_bytes = ReadFile(inv.source);
  }
  if (!inv.cacheable || !source_bytes || !cache.Connect(socket_path)) {
    int status = 0;
    {
      std::optional<Slot> slot;
      if (!inv.source.empty()) {  // not `rustc -vV` and such
        slot.emplace(cache, socket_path);
      }
      status = Run(rustc, inv.args, StderrMode::kInherit).status;
    }
    Outcome outcome = Outcome::kPlainNoSocket;
    if (inv.query) {
      outcome = Outcome::kPlainQuery;
    } else if (!inv.cacheable) {
      outcome = Outcome::kPlainCompile;
    } else if (!source_bytes) {
      outcome = Outcome::kPlainNoSource;
    }
    LogOutcome("rustc", outcome, label, clock);
    return status;
  }

  Store& store = Store::Get();
  store.LearnRoots(rustc);
  for (const std::string& arg : inv.key_args) {
    store.LearnRoots(arg);
  }
  Hasher hasher;
  // bumped when what a key covers changes, so entries made under the old rules are not asked for
  hasher.Field("rs-schema=5");
  // cargo may hand us a bare `rustc`: resolve on PATH first, or two toolchains share a key
  hasher.Field("rustc=" + store.ToolId(OnPath(rustc)));
  hasher.Field("cwd=" + store.Key(fs::current_path().string()));
  for (const std::string& arg : inv.key_args) {
    hasher.Field(store.Key(arg));
  }
  for (const std::string& rlib : inv.externs) {
    hasher.Field("extern:" + store.InputId(rlib).value_or("?"));
  }
  if (inv.links) {
    HashLinkInputs(hasher, inv, store, OnPath(rustc));
  }
  for (const char* var :
       {"CARGO_PKG_NAME", "CARGO_PKG_VERSION", "CARGO_CFG_TARGET_FEATURE", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS"}) {
    hasher.Field(std::format("{}={}", var, Env(var)));
  }
  hasher.Field(*source_bytes);
  const RequestKey request_key(Tool::kRustc, hasher.Finish());

  // the log's subject says how far a miss got
  std::string missed = label + " new-key";
  if (const std::optional<std::string> manifest = cache.Get(slot::Manifest(request_key))) {
    std::string stale;
    const std::optional<ResultKey> result_key = ValidateManifest(cache, request_key, *manifest, &stale);
    missed = label + " inputs-changed:" + stale;
    if (result_key) {
      missed = label + " object-gone";
      const std::optional<std::string> blob = cache.Get(slot::Object(*result_key));
      if (blob && UnpackFiles(*blob, inv.out_dir, inv.extra_filename)) {
        std::print(stderr, "{}", cache.Get(slot::Stderr(*result_key)).value_or(""));
        LogOutcome("rustc", Outcome::kHit, label, clock);
        return 0;
      }
    }
  }

  RunResult run;
  {
    const Slot slot(cache, "");
    run = Run(rustc, inv.args, StderrMode::kCapture);
  }
  std::print(stderr, "{}", run.stderr_text);
  if (run.status != 0) {
    LogOutcome("rustc", Outcome::kMissFail, missed, clock);
    return run.status;
  }
  // with cargo the dep-info is exactly <out-dir>/<crate><extra>.d. Scanning would race sibling variants
  const std::optional<std::string> dep_text =
      ReadFile(fs::path(inv.out_dir) / (inv.crate_name + inv.extra_filename + ".d"));
  if (!dep_text) {
    LogOutcome("rustc", Outcome::kMissUnstored, missed, clock);
    return 0;
  }
  const DepInfo info = ParseDepInfo(*dep_text);
  // "# env-dep:" lines (env!() inputs) are not tracked yet. CARGO_PKG_* are in k1
  const Manifest manifest =
      BuildManifest(cache, request_key, info.inputs, fs::absolute(inv.source).lexically_normal().string());
  cache.Put(slot::Manifest(request_key), manifest.text);
  cache.Put(slot::Object(manifest.result_key), PackFiles(info.outputs, inv.extra_filename));
  cache.Put(slot::Stderr(manifest.result_key), run.stderr_text);
  LogOutcome("rustc", Outcome::kMissStored, missed, clock);
  return 0;
}

}  // namespace jig
