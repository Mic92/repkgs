// Plain-assert unit tests for the pure parts of jig. Built and run by pkgs/ji/jig/bootstrap.nu
// before the binary is installed; also: c++ -std=c++26 ... jig_test.cc <srcs> && ./a.out
#include <stdlib.h>  // NOLINT(modernize-deprecated-headers): setenv is POSIX
#include <unistd.h>

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <initializer_list>
#include <print>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base.h"
#include "cache_client.h"
#include "cc_mode.h"
#include "driver.h"
#include "fixup_mode.h"
#include "gocache_mode.h"
#include "keys.h"
#include "manifest.h"
#include "nix_store_mode.h"
#include "process.h"
#include "rustc_mode.h"
#include "store.h"

namespace {

namespace fs = jig::fs;
using jig::ExpandResponseFiles;
using jig::Invocation;
using jig::ParseInvocation;
using jig::WriteFile;

auto V(std::initializer_list<const char*> items) -> std::vector<std::string> { return {items.begin(), items.end()}; }

#define VENDOR_ROOT \
  JIG_STORE_DIR "/0123456789abcdfghijklmnpqrsvwxyz-cargo-vendor"  // NOLINT(cppcoreguidelines-macro-usage): setenv
#define OUT_ROOT \
  JIG_STORE_DIR "/9123456789abcdfghijklmnpqrsvwxyz-openssl"  // NOLINT(cppcoreguidelines-macro-usage): setenv
                                                             // before statics
constexpr std::string_view kVendor = VENDOR_ROOT;

void TestBase() {
  assert(jig::SplitWhitespace("  a  b\tc\n") == V({"a", "b", "c"}));
  assert(jig::Split("a::b:", ':') == V({"a", "b"}));
  assert(jig::Join(V({"a", "b"}), ", ") == "a, b");
  assert(jig::Trim("  x \t") == "x");
  assert(jig::ReplaceAll("a-b-c", "-", "+") == "a+b+c");
  assert(jig::ParseUint("42") == 42U);
  constexpr int kOctal = 8;
  assert(jig::ParseUint("755", kOctal) == 0755U);
  assert(!jig::ParseUint("4x"));
  assert(!jig::ParseUint(""));
  assert(jig::HexEncode(std::string("\x01\xff", 2)) == "01ff");
  // BLAKE3 test vector: empty input
  jig::Hasher const empty;
  assert(empty.Finish().hex() == "af1349b9f5f9a1a6a0404dea36dcc949");
  jig::Hasher left;
  jig::Hasher right;
  left.Field("ab").Field("c");
  right.Field("a").Field("bc");
  assert(left.Finish() != right.Finish());
  assert(!jig::WriteFile("/nonexistent/dir/file", "x"));
  const std::string big(300000, 'y');
  assert(jig::WriteFile("/tmp/jig_test.big", big));
  assert(jig::ReadFile("/tmp/jig_test.big") == big);
  assert(jig::Deterministic({.status = 1, .stderr_text = "x.c:1: error: foo"}));
  assert(!jig::Deterministic({.status = 137, .stderr_text = ""}));
  assert(!jig::Deterministic({.status = 1, .stderr_text = "clang: error: unable to execute command: Killed"}));
}

void TestStoreMask() {
  jig::Store const& store = jig::Store::Get();
  const std::string dir = store.dir();
  assert(store.IsStorePath(dir + "/x"));
  assert(!store.IsStorePath(dir));
  assert(!store.IsStorePath("/tmp/x"));
  const std::string header = dir + "/0123456789abcdfghijklmnpqrsvwxyz-glibc-2.44/include/stdio.h";
  assert(store.MaskHashes(header) == dir + "/*-glibc-2.44/include/stdio.h");
  assert(store.MaskHashes("-I" + header + " -I" + header) ==
         "-I" + store.MaskHashes(header) + " -I" + store.MaskHashes(header));
  assert(store.MaskHashes(dir + "/short-name") == dir + "/short-name");
  const std::string once = dir + "/*-linux-headers-boot/include/asm-generic/errno.h";  // byte 32 after '*' is '-'
  assert(store.MaskHashes(once) == once);
  // the own output's hash is a fixed placeholder in what is keyed and stored, and comes back
  const std::string define = "-DENGINESDIR=\"" OUT_ROOT "/lib/engines\"";
  const std::string masked = store.MaskOut(define);
  assert(masked == "-DENGINESDIR=\"" JIG_STORE_DIR "/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-openssl/lib/engines\"");
  assert(store.UnmaskOut(masked) == define);
  assert(store.MaskOut(header) == header);
  // a literal run of 'e' that is not a store path stays
  const std::string pad = "char pad[] = \"" + std::string(40, 'e') + "\";";
  assert(store.UnmaskOut(pad) == pad);
}

// Key(): lexical path normalisation for path-valued args, other text untouched
void TestStoreKey() {
  jig::Store const& store = jig::Store::Get();
  const std::string dir = store.dir();
  assert(store.Key("-I./include//sub/../") == "-Iinclude");
  assert(store.Key("-I" + dir + "/h-x/include/.") == store.MaskHashes("-I" + dir + "/h-x/include"));
  assert(store.Key("./src/../src/a.c") == "src/a.c");
  assert(store.Key("--sysroot=/a/b/../c/") == "--sysroot=/a/c");
  // cmake's random probe names collapse to one key
  assert(store.Key("/b/CMakeFiles/CMakeScratch/TryCompile-teSZ4z/src.c") ==
         store.Key("/b/CMakeFiles/CMakeScratch/TryCompile-EaIIUC/src.c"));
  assert(store.Key("CMakeFiles/cmTC_7c7e5.dir/x.c.o") == "CMakeFiles/cmTC_#####.dir/x.c.o");
  assert(store.Key("-O2") == "-O2");
  assert(store.Key("-DFOO=./a//b") == "-DFOO=./a//b");
  assert(store.Key("-std=c++23") == "-std=c++23");
  assert(store.Key(".") == ".");
}

void TestStoreResolve() {
  jig::Store const& store = jig::Store::Get();
  const std::string dir = store.dir();
  // kVendor is in $JIG_STORE_ROOTS (main), an unrelated root is not
  const std::string vendor(kVendor);
  const std::string vendored = vendor + "/x-1.0/src/util.rs";
  assert(store.Resolve(store.MaskHashes(vendored)) == vendored);
  assert(!store.Resolve(dir + "/*-elsewhere/f.h"));
  assert(store.Resolve("/tmp/f.h") == "/tmp/f.h");
  // a config text from another build: its root becomes ours, quoted or not, longer names untouched
  const std::string other = dir + "/" + std::string(jig::kStoreHashLength, 'a') + vendor.substr(vendor.find('-'));
  assert(store.ResolveAll("p=\"" + other + "/x\" q=" + other + "-ng/y") ==
         "p=\"" + vendor + "/x\" q=" + store.MaskHashes(other) + "-ng/y");
}

// two packages whose bin/rustc link to one launcher: distinct ids, the launcher not in them
void TestStoreToolId() {
  jig::Store const& store = jig::Store::Get();
  assert(store.ToolId("/no/such/tool") == "/no/such/tool");
  const fs::path tmp = fs::temp_directory_path() / ("jig-toolid-" + std::to_string(::getpid()));
  for (const char* pkg : {"rust-a", "rust-b"}) {
    fs::create_directories(tmp / pkg / "bin");
    fs::create_symlink(tmp / "launch", tmp / pkg / "bin/rustc");
  }
  jig::WriteFile(tmp / "launch", "");
  fs::create_directory_symlink(tmp / "rust-a", tmp / "alias");
  assert(store.ToolId(tmp / "rust-a/bin/rustc") == (tmp / "rust-a/bin/rustc").string());
  assert(store.ToolId(tmp / "rust-a/bin/rustc") != store.ToolId(tmp / "rust-b/bin/rustc"));
  assert(store.ToolId(tmp / "alias/bin/rustc") == store.ToolId(tmp / "rust-a/bin/rustc"));
  fs::remove_all(tmp);
}

// cgo writes the joined -o form
void TestParseJoinedOutput() {
  const Invocation inv = ParseInvocation(V({"-c", "foo.c", "-o/tmp/b/x.o"}));
  assert(inv.cacheable && inv.output == "/tmp/b/x.o" && inv.key_args == V({"-c"}));
}

// ghc hands cc everything in one @rsp: -shared in there must still count (no crt_interp.o).
// Words follow the GNU quoting clang reads
void TestResponseFiles() {
  const fs::path dir = fs::temp_directory_path() / "jig-rsp-test";
  fs::create_directories(dir);
  assert(WriteFile(dir / "a.rsp", "-shared '-o' 'lib sp.so'\nx.o y\\ z.o \"q\\\"\"\n"));
  const std::vector<std::string> got =
      ExpandResponseFiles(std::vector<std::string>{"-O", "@" + (dir / "a.rsp").string(), "@missing"});
  assert(got == V({"-O", "-shared", "-o", "lib sp.so", "x.o", "y z.o", "q\"", "@missing"}));
  fs::remove_all(dir);
}

void TestParseLink() {
  Invocation inv = ParseInvocation(V({"-o", "prog", "main.o", "libutil.a", "-lz", "-shared"}));
  assert(inv.cacheable && inv.link && !inv.link_one && inv.output == "prog" && inv.source == "prog");
  assert(inv.inputs == V({"main.o", "libutil.a"}));

  inv = ParseInvocation(V({"-o", "prog", "-Wl,@objs.rsp"}));
  assert(!inv.cacheable);

  inv = ParseInvocation(V({"-shared", "-o", "x.so"}));
  assert(!inv.cacheable);

  inv = ParseInvocation(V({"-r", "-o", "m.o", "a.os", "-Wl,-Map,m.mapT"}));
  assert(inv.link && !inv.cacheable);

  // a "does this flag compile" probe: nothing to store, and no temp files beside /dev/null
  inv = ParseInvocation(V({"-mabi=lp64d", "-c", "cpuid.c", "-o", "/dev/null"}));
  assert(!inv.cacheable);
}

void TestParseInvocation() {
  Invocation inv = ParseInvocation(V({"-O2", "-c", "foo.c", "-o", "out/foo.o", "-MD", "-MF", "out/foo.d", "-MT", "x"}));
  assert(inv.cacheable && inv.compile_only && !inv.link_one);
  assert(inv.source == "foo.c" && inv.output == "out/foo.o");
  assert(inv.wants_depfile && inv.depfile == "out/foo.d");
  assert(inv.key_args == V({"-O2", "-c"}));

  inv = ParseInvocation(V({"-c", "dir/foo.c"}));
  assert(inv.cacheable && inv.output == "foo.o" && !inv.wants_depfile);

  inv = ParseInvocation(V({"-c", "foo.c", "-MD"}));
  assert(inv.wants_depfile && inv.depfile == "foo.d");

  inv = ParseInvocation(V({"-Wp,-MMD,scripts/.fixdep.d", "-o", "fixdep", "fixdep.c"}));
  assert(inv.cacheable && inv.link_one && inv.wants_depfile && inv.depfile == "scripts/.fixdep.d" &&
         inv.output == "fixdep");

  inv = ParseInvocation(V({"-O2", "conftest.c"}));
  assert(inv.cacheable && inv.link_one && inv.output == "a.out");

  inv = ParseInvocation(V({"-o", "conftest", "conftest.c", "conftstm.o"}));
  assert(!inv.cacheable);

  inv = ParseInvocation(V({"-shared", "-o", "lib.so", "a.c"}));
  assert(!inv.cacheable);

  for (const char* flag : {"-M", "--version", "-print-search-dirs", "-fsyntax-only"}) {
    inv = ParseInvocation(V({flag, "conftest.c"}));
    assert(!inv.cacheable);
  }
  inv = ParseInvocation(V({"-c", "a.c", "b.c"}));
  assert(!inv.cacheable);
  inv = ParseInvocation(V({"-c", "-x", "c", "-"}));
  assert(!inv.cacheable);
}

// configure's preprocessor probes: cached like a compile, -E/-S part of the key, text to stdout without -o
void TestParsePch() {
  Invocation inv = ParseInvocation(V({"-x", "c++-header", "pch.hxx", "-o", "pch.hxx.pch", "-c"}));
  assert(!inv.cacheable);
  inv = ParseInvocation(V({"-Xclang", "-emit-pch", "-c", "cmake_pch.hxx.cxx", "-o", "cmake_pch.hxx.pch"}));
  assert(!inv.cacheable);
  inv = ParseInvocation(V({"-include-pch", "x.pch", "-c", "a.cc", "-o", "a.o"}));
  assert(inv.cacheable && inv.pch == V({"x.pch"}));
  inv = ParseInvocation(V(
      {"-Xclang", "-include-pch", "-Xclang", "/b/x.pch", "-Xclang", "-include", "-Xclang", "/b/x.hxx", "-c", "a.cc"}));
  assert(inv.cacheable && inv.pch == V({"/b/x.pch"}) && inv.source == "a.cc");
}

void TestParsePreprocess() {
  Invocation inv = ParseInvocation(V({"-std=gnu23", "-E", "conftest.c"}));
  assert(inv.cacheable && inv.compile_only && inv.to_stdout && inv.key_args == V({"-std=gnu23", "-E"}));
  inv = ParseInvocation(V({"-E", "conftest.c", "-o", "-"}));
  assert(inv.cacheable && inv.to_stdout);
  inv = ParseInvocation(V({"-E", "-o", "x.i", "x.c"}));
  assert(inv.cacheable && !inv.to_stdout && inv.output == "x.i");
  inv = ParseInvocation(V({"-S", "x.c"}));
  assert(inv.cacheable && !inv.to_stdout && inv.output == "x.s" && inv.key_args == V({"-S"}));
  inv = ParseInvocation(V({"-E", "-"}));
  assert(!inv.cacheable);
}

void TestDepfile() {
  const std::string text = "out/foo.o: foo.c \\\n  /inc/a.h /inc/b.h \\\n /inc/sp\\ ace.h\n/inc/a.h:\n/inc/b.h:\n";
  assert(jig::ParseDepfile(text) == V({"foo.c", "/inc/a.h", "/inc/b.h", "/inc/sp ace.h"}));
  assert(jig::ParseDepfile("x: \\\n a.c\n") == V({"a.c"}));
  assert(jig::ParseDepfile("").empty());
  // lld --dependency-file
  assert(jig::ParseDepfile(
             "conftest: \\\n /s/lib/Scrt1.o \\\n /tmp/conftest-1.o \\\n /s/lib/libc.so\n\n/s/lib/libc.so:\n") ==
         V({"/s/lib/Scrt1.o", "/tmp/conftest-1.o", "/s/lib/libc.so"}));
}

void TestManifest() {
  const std::string dir = "/tmp/jig-test-" + std::to_string(::getpid());
  std::filesystem::create_directories(dir);
  jig::WriteFile(dir + "/a.h", "A");
  jig::WriteFile(dir + "/b.h", "B");
  const jig::RequestKey key(jig::Tool::kCc, jig::HashOf("k1"));
  const jig::RequestKey other(jig::Tool::kCc, jig::HashOf("other"));
  assert(jig::RequestKey(jig::Tool::kRustc, jig::HashOf("k1")).text() == "rs/" + key.text());
  jig::CacheClient offline;  // unconnected: identities are hashed locally
  const jig::Manifest manifest = jig::BuildManifest(
      offline, key, V({"src.c", (dir + "/a.h").c_str(), (dir + "/b.h").c_str(), "/nonexistent"}), "src.c");
  assert(manifest.text.starts_with(dir + "/a.h\tC:"));
  assert(jig::Split(manifest.text, '\n').size() == 2);
  assert(jig::ValidateManifest(offline, key, manifest.text) == manifest.result_key);
  assert(jig::ValidateManifest(offline, other, manifest.text) != manifest.result_key);
  assert(jig::slot::Manifest(key) == "m/" + key.text() &&
         jig::slot::Object(manifest.result_key) == "o/" + manifest.result_key.text());
  jig::WriteFile(dir + "/b.h", "B2");
  assert(jig::ValidateManifest(offline, key, manifest.text).error_or("") == "inputs-changed:" + dir + "/b.h");

  // absent lookups: a hit needs them still absent. Existing (the compiler's own output) and store paths drop out
  const jig::Manifest shadow = jig::BuildManifest(offline, key, V({"src.c", (dir + "/a.h").c_str()}), "src.c",
                                                  V({
                                                      (dir + "/early/a.h").c_str(),
                                                      (dir + "/./early//a.h").c_str(),
                                                      (dir + "/b.h").c_str(),
                                                      "/nix/store/x-y/z.h",
                                                      "",
                                                  }));
  assert(jig::Split(shadow.text, '\n') ==
         V({jig::Split(manifest.text, '\n').at(0).c_str(), ("!" + dir + "/early/a.h").c_str()}));
  assert(jig::ValidateManifest(offline, key, shadow.text) == shadow.result_key);
  std::filesystem::create_directories(dir + "/early");
  jig::WriteFile(dir + "/early/a.h", "A2");
  assert(jig::ValidateManifest(offline, key, shadow.text).error_or("") == "appeared:" + dir + "/early/a.h");
  std::filesystem::remove_all(dir);
}

const char* const kElfConf =
    R"({"cc": "/seed/bin/clang", "flags": ["--target=x", "-O2"], "cxxflags": ["-stdlib=libc++"],)"
    R"( "libc": "/sr/libc", "crt": "/cc/lib/crt_interp.o", "runtimes": "/sr/rt/lib"})";
const char* const kCoffConf =
    R"({"cc": "/seed/bin/clang", "binfmt": "coff", "flags": ["--target=x86_64-pc-windows-msvc"]})";
auto Has(const std::vector<std::string>& args, const std::string& arg) -> bool {
  return std::ranges::find(args, arg) != args.end();
}

// conf parsing, and binfmt: macho gets rpaths and @rpath ids but no interp, coff a c++14 floor and no PIC
void TestDriverConf() {
  const jig::DriverConf conf = jig::ParseDriverConf(kElfConf);
  assert(conf.present && conf.cc == "/seed/bin/clang" && conf.flags == V({"--target=x", "-O2"}));
  const jig::DriverConf fortran = jig::ParseDriverConf(
      R"({"cc": "/c", "fc": "/f/bin/flang", "fflags": ["-L@/lib", "-fintrinsic-modules-path", "@/finc", "-resource-dir=@/rd", "-Da@/b"]})",
      "/self");
  assert(fortran.fc == "/f/bin/flang");
  assert(fortran.fflags ==
         V({"-L/self/lib", "-fintrinsic-modules-path", "/self/finc", "-resource-dir=/self/rd", "-Da@/b"}));
  const jig::DriverConf macho = jig::ParseDriverConf(
      R"({"cc": "/seed/bin/clang", "binfmt": "macho", "flags": ["--target=arm64-apple-macos14.0"], "libc": "/sr"})");
  assert(macho.binfmt == jig::BinFmt::kMachO);
  const std::string macho_exe = jig::Join(jig::BuildDriverArgs(macho, jig::Language::kC, V({"a.c", "-o", "a"})), " ");
  assert(!macho_exe.contains("dynamic-linker") && !macho_exe.contains("crt_interp") && !macho_exe.contains("$ORIGIN"));
  assert(macho_exe.contains("-Wl,-headerpad_max_install_names") && !macho_exe.contains("-rpath"));
  // COFF: PIC is not a thing to ask for
  assert(!Has(jig::BuildDriverArgs(jig::ParseDriverConf(kCoffConf), jig::Language::kC, V({"-fPIC", "-c", "a.c"})),
              "-fPIC"));
  const jig::DriverConf coff = jig::ParseDriverConf(kCoffConf);
  assert(Has(jig::BuildDriverArgs(coff, jig::Language::kCxx, V({"-std=c++11", "-c", "a.cc"})), "-std=c++14"));
  assert(Has(jig::BuildDriverArgs(coff, jig::Language::kCxx, V({"-std=gnu++17", "-c", "a.cc"})), "-std=gnu++17"));
  assert(Has(jig::BuildDriverArgs(macho, jig::Language::kCxx, V({"-std=c++11", "-c", "a.cc"})), "-std=c++11"));
  assert(!jig::Join(jig::BuildDriverArgs(coff, jig::Language::kC, V({"-c", "a.c"})), " ").contains("build-id"));

  // compile: conf flags, no link policy
  std::vector<std::string> out = jig::BuildDriverArgs(conf, jig::Language::kC, V({"-c", "a.c"}));
  assert(out == V({"--start-no-unused-arguments", "--target=x", "-O2", "-Wl,--build-id=sha1",
                   R"(-Wl,--package-metadata={"type":"repkgs"})", "--end-no-unused-arguments", "-c", "a.c"}));
  // C++ name adds driver mode + cxxflags
  out = jig::BuildDriverArgs(conf, jig::Language::kCxx, V({"-c", "a.cc"}));
  assert(out.at(3) == "--driver-mode=g++" && out.at(4) == "-stdlib=libc++");

  // -lWS2_32 names a lower-case sysroot import lib, -lLLVM-22 a mixed-case one on a -L dir
  const fs::path wlib = fs::temp_directory_path() / ("jig-coff-" + std::to_string(::getpid()));
  fs::create_directories(wlib);
  jig::WriteFile(wlib / "libLLVM-22.dll.a", "");
  out = jig::BuildDriverArgs(coff, jig::Language::kC,
                             std::vector<std::string>{"a.o", "-L" + wlib.string(), "-lWS2_32", "-lLLVM-22"});
  assert(Has(out, "-lws2_32"));
  assert(Has(out, "-lLLVM-22"));
  assert(
      Has(jig::BuildDriverArgs(coff, jig::Language::kC, V({"a.o", "-nostartfiles", "-lWS2_32.lib"})), "-lws2_32.lib"));
  out =
      jig::BuildDriverArgs(coff, jig::Language::kC, std::vector<std::string>{"a.o", "-L", wlib.string(), "-lLLVM-22"});
  assert(Has(out, "-lLLVM-22"));
  fs::remove_all(wlib);
}

// package flags: after the toolchain's, before the build system's. ldflags only when linking
void TestDriverPackageFlags() {
  jig::DriverConf pkg = jig::ParseDriverConf(kElfConf);
  pkg.package = {.cflags = V({"-O3"}), .cxxflags = V({"-fno-rtti"}), .ldflags = V({"-Wl,-z,x"})};
  std::vector<std::string> out = jig::BuildDriverArgs(pkg, jig::Language::kCxx, V({"-c", "a.cc", "-O0"}));
  assert(out == V({"--start-no-unused-arguments", "--target=x", "-O2", "-O3", "--driver-mode=g++", "-stdlib=libc++",
                   "-fno-rtti", "-Wl,--build-id=sha1", R"(-Wl,--package-metadata={"type":"repkgs"})",
                   "--end-no-unused-arguments", "-c", "a.cc", "-O0"}));
  out = jig::BuildDriverArgs(pkg, jig::Language::kC, V({"-shared", "-o", "x.so", "x.o", "-L."}));
  assert(jig::Join(out, " ").contains("x.o -L. -Wl,-z,x -Wl,"));
  // the user's --build-id comes later and wins
  out = jig::BuildDriverArgs(pkg, jig::Language::kC, V({"-Wl,--build-id=none", "x.o"}));
  assert(jig::Join(out, " ").contains(
      R"(-Wl,--package-metadata={"type":"repkgs"} --end-no-unused-arguments -Wl,--build-id=none x.o)"));
  pkg.package.cflags = V({"-O2", "-D_FORTIFY_SOURCE=3"});
  assert(jig::Join(jig::BuildDriverArgs(pkg, jig::Language::kC, V({"-c", "a.c"})), " ").contains("FORTIFY"));
  assert(!jig::Join(jig::BuildDriverArgs(pkg, jig::Language::kC, V({"-c", "a.c", "-O0"})), " ").contains("FORTIFY"));
  assert(!jig::Join(jig::BuildDriverArgs(pkg, jig::Language::kC, V({"-c", "a.c", "-O2", "-O0"})), " ").contains("=3"));
  out = jig::BuildDriverArgs(pkg, jig::Language::kC, V({"-c", "a.c", "-D_FORTIFY_SOURCE=2"}));
  assert(!jig::Join(out, " ").contains("=3") && jig::Join(out, " ").contains("=2"));
}

// executable link: rpath (runtimes only for C++), interp stub, host rpaths and foreign
// --dynamic-linker dropped. shared: rpath, no interp. static / -r / -nostartfiles: nothing
void TestDriverLink() {
  const jig::DriverConf conf = jig::ParseDriverConf(kElfConf);
  const std::string store = jig::Store::Get().dir();
  std::vector<std::string> out =
      jig::BuildDriverArgs(conf, jig::Language::kC,
                           V({"-o", "x", "x.c", "-Wl,-rpath,/usr/lib:/build/lib", "-Wl,--dynamic-linker=/lib/ld.so"}));
  const std::string joined = jig::Join(out, " ");
  assert(!joined.contains("/usr/lib"));
  assert(!joined.contains("/lib/ld.so "));
  assert(joined.contains("-Wl,-rpath,/build/lib:/sr/libc/lib/.:/_"));
  assert(!joined.contains("/sr/rt/lib"));
  assert(joined.contains(
      "-x none /cc/lib/crt_interp.o -Wl,--dynamic-linker=/sr/libc/lib/././././././././././././ld-linux-x86-64.so.2 "
      "-Wl,--export-dynamic-symbol=__reloc_start"));
  // cmake links with "-rpath,<build>:" and its install step insists on finding "<build>:" verbatim
  out = jig::BuildDriverArgs(conf, jig::Language::kC, V({"-o", "x", "x.c", "-Wl,-rpath,/build/build:"}));
  assert(jig::Join(out, " ").contains("-Wl,-rpath,/build/build::/sr/libc/lib/.:/_"));
  out = jig::BuildDriverArgs(conf, jig::Language::kCxx, V({"-o", "x", "x.cc"}));
  assert(jig::Join(out, " ").contains("/sr/rt/lib/.:/sr/libc/lib/.:/_"));
  out = jig::BuildDriverArgs(conf, jig::Language::kC, V({"-o", "x", "x.c", "-lc++"}));
  assert(jig::Join(out, " ").contains("/sr/rt/lib/.:/sr/libc/lib/.:/_"));
  out = jig::BuildDriverArgs(conf, jig::Language::kC, V({"-shared", "-o", "l.so", "l.c"}));
  assert(jig::Join(out, " ").contains("-rpath") && !jig::Join(out, " ").contains("crt_interp"));
  for (const char* flag : {"-static", "-static-pie", "-r", "-nostartfiles"}) {
    out = jig::BuildDriverArgs(conf, jig::Language::kC, V({flag, "-o", "x", "x.c"}));
    assert(!jig::Join(out, " ").contains("-rpath"));
  }
  // store .so by path -> its dir is rpath'd
  out = jig::BuildDriverArgs(conf, jig::Language::kC, V({"-o", "x", "x.c", (store + "/h-zlib/lib/libz.so.1").c_str()}));
  assert(jig::Join(out, " ").contains("-rpath," + store + "/h-zlib/lib/.:/sr/libc/lib/.:/_"));
  assert(jig::IsSharedLibName("libz.so") && jig::IsSharedLibName("libz.so.1.3") && !jig::IsSharedLibName("libz.son") &&
         !jig::IsSharedLibName("x.o"));
}

// cargo runs rustc from the workspace root and dep-info names module files relative to it
void TestDepInfo() {
  const jig::DepInfo info = jig::ParseDepInfo(
      "out/t.d: src/lib.rs src/m.rs\n\nout/libt.rlib: src/lib.rs src/m.rs\n\nsrc/lib.rs:\nsrc/m.rs:\n# env-dep:X\n");
  assert(info.outputs == V({"out/t.d", "out/libt.rlib"}));
  const std::string cwd = std::filesystem::current_path().string();
  assert(info.inputs == V({(cwd + "/src/lib.rs").c_str(), (cwd + "/src/m.rs").c_str()}));
}

void TestRustInvocation() {
  jig::RustInvocation inv = jig::ParseRustInvocation(V({
      "--crate-name",
      "foo",
      "--edition=2021",
      "src/lib.rs",
      "--crate-type",
      "lib",
      "--emit=dep-info,metadata,link",
      "-C",
      "metadata=abcd",
      "-C",
      "extra-filename=-abcd",
      "--out-dir",
      "/b/deps",
      "-L",
      "dependency=/b/deps",
      "--extern",
      "bar=/b/deps/libbar-1.rmeta",
      "--cap-lints",
      "allow",
  }));
  assert(inv.cacheable && inv.source == "src/lib.rs" && inv.crate_name == "foo" && inv.out_dir == "/b/deps" &&
         inv.extra_filename == "-abcd");
  assert(inv.externs == V({"/b/deps/libbar-1.rmeta"}));
  assert(std::ranges::contains(inv.key_args, "--crate-type=lib"));
  assert(std::ranges::contains(inv.key_args, "--cap-lints=allow"));
  assert(!std::ranges::contains(inv.key_args, "-C=metadata=abcd"));
  assert(!inv.links);
  inv = jig::ParseRustInvocation(V({
      "--crate-name",
      "foo",
      "src/main.rs",
      "--crate-type",
      "bin",
      "--emit=dep-info,link",
      "--out-dir",
      "/b",
      "-C",
      "linker=clang",
      "-L",
      "native=/b/build/x/out",
  }));
  assert(inv.links && !inv.cacheable);
  inv = jig::ParseRustInvocation(V({"-", "--crate-type", "lib"}));
  assert(!inv.cacheable && inv.query);
  inv = jig::ParseRustInvocation(V({"-", "--crate-name", "___", "--print=file-names", "--crate-type", "bin"}));
  assert(inv.query);
}

void TestGoCache() {
  for (const std::string& bytes : {
           std::string(),
           std::string("a"),
           std::string("ab"),
           std::string("abc"),
           std::string("abcd"),
           std::string("\0\xff\x10", 3),
       }) {
    assert(jig::Base64Decode(jig::Base64Encode(bytes)) == bytes);
  }
  assert(jig::Base64Encode("abc") == "YWJj");
  assert(jig::Base64Encode("ab") == "YWI=");
  assert(jig::Base64Encode("a") == "YQ==");
  assert(jig::Base64Decode("YWI=") == "ab");
}

void TestBinaryImage() {
  constexpr size_t kEhdrSize = 64;
  std::string bytes(kEhdrSize, '\0');
  constexpr std::string_view kMagic =
      "\x7f"
      "ELF\x02\x01";
  bytes.replace(0, kMagic.size(), kMagic);
  jig::BinaryImage elf(bytes);
  assert(elf.IsElf64LittleEndian());
  assert(elf.Write<std::uint32_t>(16, 0xdeadbeef));
  assert(elf.Read<std::uint32_t>(16) == 0xdeadbeefU);
  assert(!elf.Read<std::uint64_t>(60));  // would run past the end
  assert(!elf.Read<std::uint16_t>(1000));
  assert(!elf.Write<std::uint64_t>(57, 1));
  assert(elf.WritePadded(32, 8, "abc"));
  assert(elf.CString(32) == "abc");
  assert(!elf.WritePadded(32, 3, "abc"));  // no room for NUL
  assert(!elf.WritePadded(60, 8, "abc"));
  assert(elf.CString(5000).empty());
  assert(!jig::BinaryImage("short").IsElf64LittleEndian());
}

// <mach-o/loader.h> layout, enough to build a dylib as ld64 leaves it: header, __TEXT mapping the
// header with one section behind the padding, LC_ID_DYLIB and LC_LOAD_DYLIBs with absolute names
namespace macho {
constexpr std::uint32_t kMagic64 = 0xfeedfacf;
constexpr std::uint32_t kHeaderSize = 32;
constexpr std::uint32_t kNcmdsField = 16;
constexpr std::uint32_t kSizeofcmdsField = 20;
constexpr std::uint32_t kSegment64 = 0x19;
constexpr std::uint32_t kSegmentSize = 72;
constexpr std::uint32_t kSectionSize = 80;
constexpr std::uint32_t kSegFilesizeField = 48;
constexpr std::uint32_t kSegNsectsField = 64;
constexpr std::uint32_t kSectOffsetField = 48;
constexpr std::uint32_t kLoadDylib = 0xc;
constexpr std::uint32_t kIdDylib = 0xd;
constexpr std::uint32_t kDylibCmdSize = 24;  // cmd, cmdsize, name offset, timestamp, two versions
constexpr std::uint32_t kAlign = 8;

auto DylibCommand(std::uint32_t cmd, std::string_view path) -> std::string {
  std::string bytes(kDylibCmdSize, '\0');
  bytes += path;
  bytes.resize((bytes.size() + kAlign) / kAlign * kAlign, '\0');
  jig::BinaryImage image(std::move(bytes));
  assert(image.Write<std::uint32_t>(0, cmd));
  assert(image.Write(4, static_cast<std::uint32_t>(image.bytes().size())));
  assert(image.Write<std::uint32_t>(kAlign, kDylibCmdSize));
  return image.bytes();
}

// text_off: where __text starts, the header room ends there
auto Dylib(std::uint32_t text_off, std::uint64_t file_size, const std::string& dylib_cmds, std::uint32_t ndylibs)
    -> std::string {
  jig::BinaryImage segment(std::string(kSegmentSize + kSectionSize, '\0'));
  assert(segment.Write<std::uint32_t>(0, kSegment64));
  assert(segment.Write<std::uint32_t>(4, kSegmentSize + kSectionSize));
  assert(segment.Write<std::uint64_t>(kSegFilesizeField, file_size));  // fileoff stays 0
  assert(segment.Write<std::uint32_t>(kSegNsectsField, 1));
  assert(segment.Write<std::uint32_t>(kSegmentSize + kSectOffsetField, text_off));
  const std::string cmds = segment.bytes() + dylib_cmds;
  jig::BinaryImage file(std::string(file_size, '\0'));
  assert(file.Write<std::uint32_t>(0, kMagic64));
  assert(file.Write<std::uint32_t>(kNcmdsField, ndylibs + 1));
  assert(file.Write(kSizeofcmdsField, static_cast<std::uint32_t>(cmds.size())));
  assert(file.Overwrite(kHeaderSize, cmds));
  return file.bytes();
}
}  // namespace macho

void TestMachOFixup() {
  constexpr std::uint64_t kFileSize = 2048;
  constexpr std::uint32_t kRoomy = 1024;
  const std::string prefix_lib = std::string(OUT_ROOT) + "/lib/";
  const std::string dep = JIG_STORE_DIR "/7123456789abcdfghijklmnpqrsvwxyz-zlib/lib/libz.1.dylib";
  // an @rpath id (cmake's default) becomes absolute, an @rpath load of our own dylib @loader_path
  const std::string dylibs = macho::DylibCommand(macho::kIdDylib, "@rpath/libssl.3.dylib") +
                             macho::DylibCommand(macho::kLoadDylib, "@rpath/libcrypto.3.dylib") +
                             macho::DylibCommand(macho::kLoadDylib, dep) +
                             macho::DylibCommand(macho::kLoadDylib, "/usr/lib/libSystem.B.dylib");
  const std::string file = macho::Dylib(kRoomy, kFileSize, dylibs, 4);

  const fs::path tmp = fs::temp_directory_path() / ("jigtest-macho-" + std::to_string(getpid()));
  fs::create_directories(tmp / "lib");
  const fs::path dylib = tmp / "lib/libssl.3.dylib";
  assert(jig::WriteFile(dylib, file));
  assert(jig::WriteFile(tmp / "lib/libcrypto.3.dylib", ""));
  jig::FixupContext ctx;
  ctx.prefix = tmp;
  ctx.dest = std::string(OUT_ROOT);
  ctx.own_lib_dirs = {tmp / "lib"};
  jig::BinaryImage image(file);
  assert(jig::FixMachO(ctx, dylib, image));
  assert(ctx.errors == 0);
  const std::string after = jig::ReadFile(dylib).value_or("");
  assert(after.size() == kFileSize);
  assert(after.contains(prefix_lib + "libssl.3.dylib"));
  assert(after.contains("@loader_path/libcrypto.3.dylib"));
  assert(after.contains("@loader_path/../../7123456789abcdfghijklmnpqrsvwxyz-zlib/lib/libz.1.dylib"));
  assert(after.contains("/usr/lib/libSystem.B.dylib"));
  assert(!after.contains("7123456789abcdfghijklmnpqrsvwxyz-zlib/") ||
         after.contains("../../7123456789abcdfghijklmnpqrsvwxyz-zlib/"));

  // loads dyld could not resolve: @rpath nothing of ours provides, a dangling @loader_path, a
  // system library the SDK lacks. One it has passes
  fs::create_directories(tmp / "sdk/usr/lib");
  assert(jig::WriteFile(tmp / "sdk/usr/lib/libSystem.B.tbd", ""));
  ctx.sdk = tmp / "sdk";
  for (const auto& [load, errors] : std::initializer_list<std::pair<const char*, int>>{
           {"@rpath/libgone.dylib", 1},
           {"@loader_path/libgone.dylib", 1},
           {"/usr/lib/libgone.dylib", 1},
           {"/usr/lib/libSystem.B.dylib", 0},
       }) {
    jig::FixupContext bad = ctx;
    const std::string lost = macho::Dylib(kRoomy, kFileSize, macho::DylibCommand(macho::kLoadDylib, load), 1);
    assert(jig::WriteFile(dylib, lost));
    jig::BinaryImage lost_image(lost);
    assert(jig::FixMachO(bad, dylib, lost_image));
    assert(bad.errors == errors);
  }

  // __text right behind the commands: the longer zlib spelling does not fit, an error
  const std::string grows = macho::DylibCommand(macho::kLoadDylib, dep);
  const auto tight_off =
      static_cast<std::uint32_t>(macho::kHeaderSize + macho::kSegmentSize + macho::kSectionSize + grows.size());
  const std::string tight = macho::Dylib(tight_off, kFileSize, grows, 1);
  assert(jig::WriteFile(dylib, tight));
  jig::BinaryImage tight_image(tight);
  assert(jig::FixMachO(ctx, dylib, tight_image));
  assert(ctx.errors == 1);
  assert(jig::ReadFile(dylib) == tight);
  fs::remove_all(tmp);
}

void TestNixStore() {
  // FIPS 180-4 vectors
  assert(jig::HexEncode(jig::Sha256("")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  assert(jig::HexEncode(jig::Sha256("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assert(jig::HexEncode(jig::Sha256(std::string(1000, 'a'))) ==
         "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3");
  // `nix hash convert --hash-algo sha256 --to nix32 <hex of sha256("abc")>`
  assert(jig::Nix32(jig::Sha256("abc")) == "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s");
  // `nix store path-from-hash-part` is not applicable. Reference: nix-prefetch-url of an empty file
  //   printf "" > e && nix store add --mode flat --hash-algo sha256 e  (name "e")
  assert(jig::FixedOutputPath("/nix/store", "e", "sha256",
                              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") ==
         "/nix/store/3hc40wwijh4im7g2i31nk75qappbjw9i-e");
  const std::string aterm = jig::DerivationToATerm(
      R"j({"name":"x","system":"x86_64-linux","builder":"/b","args":["-c","echo \"hi\"\n"],)j"
      R"j("env":{"out":"/o","b":"1","a":"2"},"inputSrcs":["/s2","/s1"],"inputDrvs":{"/d.drv":["out","dev"]},)j"
      R"j("outputs":{"out":{"hashAlgo":"r:sha256"}}})j");
  // env sorted, inputSrcs sorted, output names sorted, quotes and newline escaped
  assert(aterm == R"a(Derive([("out","","r:sha256","")],[("/d.drv",["dev","out"])],["/s1","/s2"],"x86_64-linux","/b",)a"
                  R"a(["-c","echo \"hi\"\n"],[("a","2"),("b","1"),("out","/o")]))a");
}

}  // namespace

// NOLINTNEXTLINE(bugprone-exception-escape): a throwing test is a failing test
auto main() -> int {
  setenv("JIG_STORE_IDENTITY", "content", 1);  // NOLINT(concurrency-mt-unsafe): before any Store::Get
  setenv("JIG_STORE_ROOTS", VENDOR_ROOT, 1);   // NOLINT(concurrency-mt-unsafe)
  setenv("out", OUT_ROOT, 1);                  // NOLINT(concurrency-mt-unsafe)
  TestBase();
  TestStoreMask();
  TestStoreKey();
  TestStoreResolve();
  TestStoreToolId();
  TestParseInvocation();
  TestParsePch();
  TestParsePreprocess();
  TestParseLink();
  TestParseJoinedOutput();
  TestResponseFiles();
  TestDepfile();
  TestManifest();
  TestDriverConf();
  TestDriverPackageFlags();
  TestDriverLink();
  TestDepInfo();
  TestRustInvocation();
  TestGoCache();
  TestBinaryImage();
  TestMachOFixup();
  TestNixStore();
  std::println("jig_test: ok");
  return 0;
}
