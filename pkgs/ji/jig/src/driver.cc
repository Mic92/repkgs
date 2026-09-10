#include "driver.h"

#include <algorithm>
#include <cstddef>
#include <filesystem>
#include <format>
#include <json.hpp>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "base.h"
#include "keys.h"
#include "store.h"

namespace jig {

namespace {

namespace fs = std::filesystem;

auto RealDir(const std::string& path) -> std::string {
  std::error_code error;
  const fs::path canonical = fs::canonical(path, error);
  return error ? path : canonical.string();
}

auto IsHostDir(std::string_view path) -> bool {
  return path.starts_with("/usr") || path.starts_with("/lib") || path.starts_with("/opt");
}

// Ordered, de-duplicated RUNPATH under construction.
class RunpathList {
 public:
  void Add(const std::string& dir) {
    if (IsHostDir(dir) || std::ranges::contains(entries_, dir)) {
      return;
    }
    entries_.push_back(dir);
  }
  // build-system rpaths keep their exact text incl. duplicates and empty elements: cmake's install
  // step string-matches "<build dir>:" in the binary before rewriting it. Host dirs are dropped
  void AddVerbatim(std::string_view rpath) {
    for (const std::string& part : Split(rpath, ':', /*keep_empty=*/true)) {
      if (!IsHostDir(part)) {
        verbatim_.append(part).push_back(':');
      }
    }
  }
  // verbatim prefix first, then ours, then one pad entry giving `jig fixup` kRunpathSlack bytes
  // per store entry to rewrite them $ORIGIN-relative in place. Ours end in "/.": meson's install
  // step deletes every RUNPATH element that string-equals a build rpath or dependency libdir it
  // knows, which would take ours with it. fixup normalises the spelling away. `libs`: -l count, each
  // may become a direct $ORIGIN NEEDED string in the same bytes
  [[nodiscard]] auto Render(size_t libs) const -> std::string {
    std::string out = verbatim_;
    for (const std::string& entry : entries_) {
      out.append(entry).append("/.:");
    }
    const size_t stores = entries_.size() + static_cast<size_t>(std::ranges::count(verbatim_, ':'));
    return out + "/" + std::string((std::max<size_t>(stores, 1) * kRunpathSlack) + (libs * kNeededSlack) - 1, '_');
  }

 private:
  std::string verbatim_;
  std::vector<std::string> entries_;
};

// -Wl,-rpath in all the spellings build systems use. Returns the value and advances idx past it.
auto TakeRpathArg(std::span<const std::string> args, size_t& idx) -> std::optional<std::string> {
  const std::string& arg = args.at(idx);
  if ((arg == "-Wl,-rpath" || arg == "-Wl,--rpath") && idx + 1 < args.size() && args.at(idx + 1).starts_with("-Wl,")) {
    return args.at(++idx).substr(4);
  }
  for (std::string_view const spelling : {"-Wl,-rpath,", "-Wl,--rpath,", "-Wl,-rpath=", "-Wl,--rpath="}) {
    if (arg.starts_with(spelling)) {
      return arg.substr(spelling.size());
    }
  }
  if (arg == "-Xlinker" && idx + 3 < args.size() && (args.at(idx + 1) == "-rpath" || args.at(idx + 1) == "--rpath") &&
      args.at(idx + 2) == "-Xlinker") {
    idx += 3;
    return args.at(idx);
  }
  return std::nullopt;
}

auto IsOutputOnlyMode(std::string_view arg) -> bool {
  return arg == "-c" || arg == "-E" || arg == "-S" || arg == "-M" || arg == "-MM" || arg == "-fsyntax-only" ||
         arg == "-###";
}

// static and partial (-r) links and anything refusing start files get no interp/crt/rpath policy
auto RefusesLinkPolicy(std::string_view arg) -> bool {
  return arg == "-static" || arg == "-static-pie" || arg == "-r" || arg == "-Wl,-r" || arg == "-nostartfiles";
}

auto IsRuntimeLib(std::string_view lib) -> bool {
  return lib == "c++" || lib == "stdc++" || lib == "gcc_s" || lib == "unwind" || lib == ":libunwind.so";
}

struct UserArgs {
  std::vector<std::string> args;  // rpath and dynamic-linker requests removed
  RunpathList runpath;            // seeded with the build system's rpaths
  bool linking = true;
  bool have_input = false;
  bool shared = false;
  bool no_policy = false;
  bool optimizes = true;
  bool sets_fortify = false;
};

auto IsFortifyArg(std::string_view arg) -> bool {
  return arg.starts_with("-D_FORTIFY_SOURCE") || arg == "-U_FORTIFY_SOURCE" ||
         arg.starts_with("-Wp,-D_FORTIFY_SOURCE") || arg.starts_with("-Wp,-U_FORTIFY_SOURCE");
}

auto ScanUserArgs(std::span<const std::string> raw) -> UserArgs {
  UserArgs user;
  for (size_t i = 0; i < raw.size(); ++i) {
    if (std::optional<std::string> rpath = TakeRpathArg(raw, i)) {
      user.runpath.AddVerbatim(*rpath);
      continue;
    }
    const std::string& arg = raw.at(i);
    if (arg.starts_with("-Wl,--dynamic-linker") || arg.starts_with("-Wl,-dynamic-linker")) {
      continue;  // ours wins
    }
    user.linking = user.linking && !IsOutputOnlyMode(arg);
    user.shared = user.shared || arg == "-shared";
    user.no_policy = user.no_policy || RefusesLinkPolicy(arg);
    user.have_input = user.have_input || !arg.starts_with('-');
    user.sets_fortify = user.sets_fortify || IsFortifyArg(arg);
    if (arg.starts_with("-O")) {
      user.optimizes = arg != "-O0";
    }
    user.args.push_back(arg);
  }
  return user;
}

// RUNPATH: store -L dirs that satisfy some -l, store .so given by path, the C++ runtime, libc.
// Returns the -l count
auto AddRunpathEntries(const DriverConf& conf, bool cxx, std::span<const std::string> args, RunpathList& runpath)
    -> size_t {
  const Store& store = Store::Get();
  std::vector<std::string> lib_dirs;
  std::vector<std::string> libs;
  bool links_runtime = cxx;
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string& arg = args.at(i);
    const auto value_of = [&](std::string_view flag) -> std::optional<std::string> {
      if (!arg.starts_with(flag)) {
        return std::nullopt;
      }
      if (arg.size() > flag.size()) {
        return arg.substr(flag.size());
      }
      if (i + 1 < args.size()) {
        return args.at(i + 1);
      }
      return std::nullopt;
    };
    if (std::optional<std::string> dir = value_of("-L")) {
      lib_dirs.push_back(*dir);
    } else if (std::optional<std::string> lib = value_of("-l")) {
      links_runtime = links_runtime || IsRuntimeLib(*lib);
      libs.push_back(*std::move(lib));
    } else if (store.IsStorePath(arg) && IsSharedLibName(fs::path(arg).filename().string())) {
      runpath.Add(fs::path(RealDir(arg)).parent_path().string());
    }
    if (arg == "-nostdlib++" || arg == "-nostdlib") {
      links_runtime = false;
    }
  }
  for (const std::string& dir : lib_dirs) {
    const std::string real = RealDir(dir);
    if (store.IsStorePath(real) && std::ranges::any_of(libs, [&](const std::string& lib) -> bool {
          return fs::exists(std::format("{}/lib{}.so", real, lib));
        })) {
      runpath.Add(real);
    }
  }
  if (links_runtime && !conf.runtimes.empty()) {
    runpath.Add(conf.runtimes);
  }
  runpath.Add(conf.libc + "/lib");
  return libs.size();
}

// $PKGS_CC (builder/env.nu): {"<toolchain root>": {cflags, cxxflags, ldflags}}. cc-build's
// root has no entry, so host helpers get toolchain flags only
auto PackageFlags(const fs::path& root) -> PackageCcFlags {
  PackageCcFlags flags;
  const std::string text = Env("PKGS_CC");
  if (text.empty()) {
    return flags;
  }
  const nlohmann::json all = nlohmann::json::parse(text, nullptr, /*allow_exceptions=*/false);
  const auto entry = all.find(root.string());
  if (!all.is_object() || entry == all.end()) {
    return flags;
  }
  const auto list = [&](const char* key) -> std::vector<std::string> {
    const auto found = entry->find(key);
    return found == entry->end() ? std::vector<std::string>{} : found->get<std::vector<std::string>>();
  };
  flags.cflags = list("cflags");
  flags.cxxflags = list("cxxflags");
  flags.ldflags = list("ldflags");
  return flags;
}

}  // namespace

auto ParseDriverConf(std::string_view text) -> DriverConf {
  DriverConf conf;
  conf.present = true;
  for (const std::string& raw_line : Split(text, '\n')) {
    const std::string_view line = Trim(raw_line);
    const size_t equals = line.find('=');
    if (line.empty() || line.starts_with('#') || equals == std::string_view::npos) {
      continue;
    }
    const std::string key(Trim(line.substr(0, equals)));
    const std::string value(Trim(line.substr(equals + 1)));
    if (key == "cc") {
      conf.cc = value;
    } else if (key == "flags") {
      conf.flags = SplitWhitespace(value);
    } else if (key == "cxxflags") {
      conf.cxxflags = SplitWhitespace(value);
    } else if (key == "libc") {
      conf.libc = value;
    } else if (key == "interp") {
      conf.interp = value;
    } else if (key == "crt") {
      conf.crt = value;
    } else if (key == "runtimes") {
      conf.runtimes = value;
    } else if (key == "prefix-map") {
      conf.prefix_map = Split(value, ':');
    }
  }
  return conf;
}

auto LoadDriverConf() -> std::optional<DriverConf> {
  std::error_code error;
  const fs::path self = fs::read_symlink("/proc/self/exe", error);
  if (!error) {
    const fs::path root = self.parent_path().parent_path();
    if (const std::optional<std::string> text = ReadFile(root / "etc/jig.conf")) {
      DriverConf conf = ParseDriverConf(*text);
      if (conf.cc.empty()) {
        return std::nullopt;
      }
      conf.package = PackageFlags(root);
      return conf;
    }
  }
  DriverConf conf;
  conf.cc = Env("JIG_CC");
  if (conf.cc.empty()) {
    return std::nullopt;
  }
  return conf;
}

auto IsSharedLibName(std::string_view base) -> bool {
  constexpr std::string_view kSuffix = ".so";
  const size_t suffix_pos = base.rfind(kSuffix);
  if (suffix_pos == std::string_view::npos) {
    return false;
  }
  const std::string_view tail = base.substr(suffix_pos + kSuffix.size());
  if (tail.empty()) {
    return true;
  }
  return tail.at(0) == '.' &&
         std::ranges::all_of(tail.substr(1), [](char chr) -> bool { return chr == '.' || (chr >= '0' && chr <= '9'); });
}

auto BuildDriverArgs(const DriverConf& conf, Language lang, std::span<const std::string> raw_args)
    -> std::vector<std::string> {
  const bool cxx = lang == Language::kCxx;
  UserArgs user = ScanUserArgs(raw_args);
  // toolchain, then package, then build system: later wins. The bracket silences
  // unused-argument warnings for flags the step does not use
  std::vector<std::string> out{"--start-no-unused-arguments"};
  out.insert(out.end(), conf.flags.begin(), conf.flags.end());
  // glibc rejects _FORTIFY_SOURCE under -O0, and the command line's own level wins
  for (const std::string& flag : conf.package.cflags) {
    if (IsFortifyArg(flag) && (user.sets_fortify || !user.optimizes)) {
      continue;
    }
    out.push_back(flag);
  }
  if (cxx) {
    out.emplace_back("--driver-mode=g++");
    out.insert(out.end(), conf.cxxflags.begin(), conf.cxxflags.end());
    out.insert(out.end(), conf.package.cxxflags.begin(), conf.package.cxxflags.end());
  }
  out.emplace_back("--end-no-unused-arguments");
  out.insert(out.end(), user.args.begin(), user.args.end());
  // dependency -L dirs after the build tree's own, like a system lib dir would be
  if (user.linking && user.have_input) {
    out.insert(out.end(), conf.package.ldflags.begin(), conf.package.ldflags.end());
  }
  for (const std::string& mapping : conf.prefix_map) {
    out.push_back("-ffile-prefix-map=" + mapping);
  }
  for (const std::string& mapping : Split(Env("PKGS_PREFIX_MAP"), ':')) {
    out.push_back("-ffile-prefix-map=" + mapping);
  }
  if (!user.linking || !user.have_input || user.no_policy || conf.libc.empty()) {
    return out;
  }

  // RUNPATH candidates: -L dirs from argv as well as from $PKGS_CC
  std::vector<std::string> link_args = user.args;
  link_args.insert(link_args.end(), conf.package.ldflags.begin(), conf.package.ldflags.end());
  const size_t libs = AddRunpathEntries(conf, cxx, link_args, user.runpath);
  out.insert(out.end(),
             {"-Wl,--undefined-version", "-Wl,-rpath," + user.runpath.Render(libs), "-Wl,--enable-new-dtags"});

  const std::string libc_lib = conf.libc + "/lib";
  if (user.shared) {
    return out;
  }
  if (conf.crt.empty()) {
    out.push_back("-Wl,--dynamic-linker=" + libc_lib + "/" + conf.interp);
    return out;
  }
  std::string dots;
  for (int i = 0; i < kInterpSlack; ++i) {
    dots += "./";
  }
  // after the user's args, so a trailing `-x c` (ghc's configure) must not claim the object
  out.insert(out.end(), {
                            "-x",
                            "none",
                            conf.crt,
                            "-Wl,--dynamic-linker=" + libc_lib + "/" + dots + conf.interp,
                            "-Wl,--export-dynamic-symbol=__reloc_start",
                        });
  return out;
}

}  // namespace jig
