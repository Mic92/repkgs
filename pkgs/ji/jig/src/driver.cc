#include "driver.h"

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdlib>
#include <filesystem>
#include <format>
#include <json.hpp>
#include <optional>
#include <print>
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
  [[nodiscard]] auto Entries() const -> const std::vector<std::string>& { return entries_; }
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
  std::vector<std::string> args;  // minus what the policy took
  RunpathList runpath;            // seeded with the build system's rpaths
  std::string output;             // -o
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

auto IsPicArg(std::string_view arg) -> bool {
  return arg == "-fPIC" || arg == "-fpic" || arg == "-fPIE" || arg == "-fpie" || arg == "-fno-PIC" ||
         arg == "-fno-pic" || arg == "-pie";
}

// "-Lx" or "-L x": the value, if args[idx] is that flag
auto FlagValue(std::span<const std::string> args, size_t idx, std::string_view flag) -> std::optional<std::string> {
  const std::string& arg = args.at(idx);
  if (!arg.starts_with(flag)) {
    return std::nullopt;
  }
  if (arg.size() > flag.size()) {
    return arg.substr(flag.size());
  }
  if (idx + 1 < args.size()) {
    return args.at(idx + 1);
  }
  return std::nullopt;
}

// RUNPATH: store -L dirs that satisfy some -l, store libs given by path, the C++ runtime, libc.
// Returns the -l count
auto AddRunpathEntries(const DriverConf& conf, bool cxx, std::span<const std::string> args, RunpathList& runpath)
    -> size_t {
  const Store& store = Store::Get();
  std::vector<std::string> lib_dirs;
  std::vector<std::string> libs;
  bool links_runtime = cxx;
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string& arg = args.at(i);
    if (std::optional<std::string> dir = FlagValue(args, i, "-L")) {
      lib_dirs.push_back(*dir);
    } else if (std::optional<std::string> lib = FlagValue(args, i, "-l")) {
      links_runtime = links_runtime || IsRuntimeLib(*lib);
      libs.push_back(*std::move(lib));
    } else if (store.IsStorePath(arg) && IsSharedLibName(fs::path(arg).filename().string())) {
      runpath.Add(fs::path(RealDir(arg)).parent_path().string());
    }
    if (arg == "-nostdlib++" || arg == "-nostdlib") {
      links_runtime = false;
    }
  }
  const auto provides = [&](const std::string& dir) -> bool {
    return std::ranges::any_of(libs, [&](const std::string& lib) -> bool {
      return fs::exists(std::format("{}/lib{}.so", dir, lib)) || fs::exists(std::format("{}/lib{}.dylib", dir, lib));
    });
  };
  for (const std::string& dir : lib_dirs) {
    const std::string real = RealDir(dir);
    if (store.IsStorePath(real) && provides(real)) {
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

// RUNPATH candidates: -L dirs from argv as well as from $PKGS_CC. Returns the -l count
auto CollectRunpath(const DriverConf& conf, bool cxx, UserArgs& user) -> size_t {
  std::vector<std::string> link_args = user.args;
  link_args.insert(link_args.end(), conf.package.ldflags.begin(), conf.package.ldflags.end());
  return AddRunpathEntries(conf, cxx, link_args, user.runpath);
}

// What differs per binary format: how the build system's arguments pass through, what every
// command line gets, and the link policy that makes the output relocatable
struct BinFmtPolicy {
  bool takes_rpath = false;  // the build system's -rpath requests become ours to render
  auto (*arg)(const std::string& arg) -> std::optional<std::string> = nullptr;  // as passed on, nullopt drops it
  void (*always)(std::vector<std::string>& out) = nullptr;
  void (*link)(const DriverConf& conf, bool cxx, UserArgs& user, std::vector<std::string>& out) = nullptr;
  void (*libs)(const DriverConf& conf, UserArgs& user) = nullptr;  // every link, -nostartfiles ones too
};

auto KeepArg(const std::string& arg) -> std::optional<std::string> { return arg; }
void NoFlags(std::vector<std::string>& /*out*/) {}
void NoLink(const DriverConf& /*conf*/, bool /*cxx*/, UserArgs& /*user*/, std::vector<std::string>& /*out*/) {}

// ELF: the build system's dynamic linker request is dropped, ours wins
auto ElfArg(const std::string& arg) -> std::optional<std::string> {
  const bool theirs = arg.starts_with("-Wl,--dynamic-linker") || arg.starts_with("-Wl,-dynamic-linker");
  return theirs ? std::nullopt : std::optional(arg);
}

// build-id for the debug split, package note to tell our links from upstream's. User args win
void ElfFlags(std::vector<std::string>& out) {
  out.emplace_back("-Wl,--build-id=sha1");
  out.emplace_back(R"(-Wl,--package-metadata={"type":"repkgs"})");
}

// RUNPATH over the store dirs padded for `jig fixup`, our dynamic linker, the crt_interp stub
void ElfLink(const DriverConf& conf, bool cxx, UserArgs& user, std::vector<std::string>& out) {
  const size_t libs = CollectRunpath(conf, cxx, user);
  out.insert(out.end(),
             {"-Wl,--undefined-version", "-Wl,-rpath," + user.runpath.Render(libs), "-Wl,--enable-new-dtags"});
  if (user.shared) {
    return;
  }
  const std::string libc_lib = conf.libc + "/lib/";
  if (conf.crt.empty()) {
    out.push_back("-Wl,--dynamic-linker=" + libc_lib + conf.interp);
    return;
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
                            "-Wl,--dynamic-linker=" + libc_lib + dots + conf.interp,
                            "-Wl,--export-dynamic-symbol=__reloc_start",
                        });
}

// Mach-O: dependents record each dylib's absolute install name, `jig fixup` respells those
// @loader_path-relative and needs header room to do so
void MachOLink(const DriverConf& /*conf*/, bool /*cxx*/, UserArgs& /*user*/, std::vector<std::string>& out) {
  out.emplace_back("-Wl,-headerpad_max_install_names");
}

// COFF: PE is position independent by construction and clang rejects the PIC flags. MSVC's STL
// has no C++11 mode, older -std requests mean c++14
auto CoffArg(const std::string& arg) -> std::optional<std::string> {
  if (IsPicArg(arg)) {
    return std::nullopt;
  }
  for (const std::string_view old : {"++98", "++03", "++0x", "++11"}) {
    if ((arg.starts_with("-std=c") || arg.starts_with("-std=gnu")) && arg.ends_with(old)) {
      return arg.substr(0, arg.size() - 2) + "14";
    }
  }
  return arg;
}

// Library names are case-insensitive on Windows and build files spell the system ones any way
// (-lWS2_32, -lWS2_32.lib). mingw-w64's import libs and the SDK's symlinks are lower-case and the
// build host compares bytes, so a -l that no -L dir has as spelled is lower-cased
void CoffLibs(const DriverConf& conf, UserArgs& user) {
  std::vector<std::string> dirs;
  for (const std::span<const std::string> args :
       {std::span<const std::string>(user.args), std::span<const std::string>(conf.package.ldflags)}) {
    for (size_t i = 0; i < args.size(); ++i) {
      if (std::optional<std::string> dir = FlagValue(args, i, "-L")) {
        dirs.push_back(*std::move(dir));
      }
    }
  }
  const auto present = [&](const std::string& name) -> bool {
    return std::ranges::any_of(dirs, [&](const std::string& dir) -> bool {
      return fs::exists(std::format("{}/lib{}.dll.a", dir, name)) || fs::exists(std::format("{}/lib{}.a", dir, name)) ||
             fs::exists(std::format("{}/{}", dir, name));
    });
  };
  for (std::string& arg : user.args) {
    if (!arg.starts_with("-l") || arg.contains('/') || present(arg.substr(2))) {
      continue;
    }
    std::transform(arg.begin() + 2, arg.end(), arg.begin() + 2,
                   [](unsigned char chr) -> char { return static_cast<char>(std::tolower(chr)); });
  }
}

auto PolicyFor(BinFmt binfmt) -> BinFmtPolicy {
  switch (binfmt) {
    case BinFmt::kMachO:
      return {.takes_rpath = false, .arg = KeepArg, .always = NoFlags, .link = MachOLink};
    case BinFmt::kCoff:
      return {.takes_rpath = false, .arg = CoffArg, .always = NoFlags, .link = NoLink, .libs = CoffLibs};
    case BinFmt::kElf:
      break;
  }
  return {.takes_rpath = true, .arg = ElfArg, .always = ElfFlags, .link = ElfLink};
}

auto ScanUserArgs(std::span<const std::string> raw, const BinFmtPolicy& policy) -> UserArgs {
  UserArgs user;
  for (size_t i = 0; i < raw.size(); ++i) {
    if (policy.takes_rpath) {
      if (std::optional<std::string> rpath = TakeRpathArg(raw, i)) {
        user.runpath.AddVerbatim(*rpath);
        continue;
      }
    }
    const std::string& arg = raw.at(i);
    if (std::optional<std::string> output = FlagValue(raw, i, "-o")) {
      user.output = *std::move(output);
    }
    std::optional<std::string> kept = policy.arg(arg);
    if (!kept) {
      continue;
    }
    user.linking = user.linking && !IsOutputOnlyMode(arg);
    user.shared = user.shared || arg == "-shared" || arg == "-dynamiclib";
    user.no_policy = user.no_policy || RefusesLinkPolicy(arg);
    user.have_input = user.have_input || !arg.starts_with('-');
    user.sets_fortify = user.sets_fortify || IsFortifyArg(arg);
    if (arg.starts_with("-O")) {
      user.optimizes = arg != "-O0";
    }
    user.args.push_back(*std::move(kept));
  }
  return user;
}

}  // namespace

auto ParseDriverConf(std::string_view text, std::string_view root) -> DriverConf {
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
    } else if (key == "fc") {
      conf.fc = value;
    } else if (key == "fflags") {
      conf.fflags = SplitWhitespace(value);
      // "@/" is jig's own prefix (a word, after '=', or glued to a short option like -L):
      // flang-rt's conf names its lib and finclude dirs relocatably
      for (std::string& flag : conf.fflags) {
        const size_t at_pos = flag.find("@/");
        const bool expands = at_pos == 0 || (at_pos == 2 && flag.starts_with('-')) ||
                             (at_pos != std::string::npos && flag.at(at_pos - 1) == '=');
        if (expands) {
          flag.replace(at_pos, 1, root);
        }
      }
    } else if (key == "binfmt") {
      if (value == "elf") {
        conf.binfmt = BinFmt::kElf;
      } else if (value == "macho") {
        conf.binfmt = BinFmt::kMachO;
      } else if (value == "coff") {
        conf.binfmt = BinFmt::kCoff;
      } else {
        std::println(stderr, "jig.conf: binfmt = {} is none of elf, macho, coff", value);
        std::exit(2);  // NOLINT(concurrency-mt-unsafe): single-threaded startup
      }
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
      DriverConf conf = ParseDriverConf(*text, root.string());
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
  if (base.ends_with(".dylib")) {
    return true;
  }
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
  const bool fortran = lang == Language::kFortran;
  const BinFmtPolicy policy = PolicyFor(conf.binfmt);
  UserArgs user = ScanUserArgs(raw_args, policy);
  // toolchain, then package, then build system: later wins. The bracket silences
  // unused-argument warnings for flags the step does not use
  // flang has no such bracket, only the blanket -Wno-
  std::vector<std::string> out{fortran ? "-Qunused-arguments" : "--start-no-unused-arguments"};
  const std::vector<std::string>& base = fortran ? conf.fflags : conf.flags;
  out.insert(out.end(), base.begin(), base.end());
  // glibc rejects _FORTIFY_SOURCE under -O0, and the command line's own level wins. flang takes
  // neither the C hardening flags nor -ffile-prefix-map
  for (const std::string& flag : fortran ? std::vector<std::string>{} : conf.package.cflags) {
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
  // before the user's args: those may end in `--` (cmake_llvm_rc), after which everything is a file
  for (const std::string& mapping : fortran ? std::vector<std::string>{} : conf.prefix_map) {
    out.push_back("-ffile-prefix-map=" + mapping);
  }
  for (const std::string& mapping : fortran ? std::vector<std::string>{} : Split(Env("PKGS_PREFIX_MAP"), ':')) {
    out.push_back("-ffile-prefix-map=" + mapping);
  }
  policy.always(out);
  if (!fortran) {
    out.emplace_back("--end-no-unused-arguments");
  }
  // dependency -L dirs after the build tree's own, like a system lib dir would be
  std::vector<std::string> tail;
  if (user.linking && user.have_input) {
    tail = conf.package.ldflags;
    if (policy.libs != nullptr) {
      policy.libs(conf, user);
    }
    if (!user.no_policy) {
      policy.link(conf, cxx, user, tail);
    }
  }
  out.insert(out.end(), user.args.begin(), user.args.end());
  out.insert(out.end(), tail.begin(), tail.end());
  return out;
}

}  // namespace jig
