// Plain-assert unit tests for the pure parts of jig. Built and run by pkgs/ji/jig/bootstrap.nu
// before the binary is installed; also: c++ -std=c++26 ... jig_test.cc <srcs> && ./a.out
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
#include "rustc_mode.h"
#include "store.h"

namespace {

namespace fs = jig::fs;
using jig::ExpandResponseFiles;
using jig::Invocation;
using jig::ParseInvocation;
using jig::WriteFile;

auto V(std::initializer_list<const char*> items) -> std::vector<std::string> { return {items.begin(), items.end()}; }

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
}

void TestStore() {
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
  // Key(): lexical path normalisation for path-valued args, other text untouched
  assert(store.Key("-I./include//sub/../") == "-Iinclude");
  assert(store.Key("-I" + dir + "/h-x/include/.") == store.MaskHashes("-I" + dir + "/h-x/include"));
  assert(store.Key("./src/../src/a.c") == "src/a.c");
  assert(store.Key("--sysroot=/a/b/../c/") == "--sysroot=/a/c");
  assert(store.Key("-O2") == "-O2");
  assert(store.Key("-DFOO=./a//b") == "-DFOO=./a//b");
  assert(jig::Store::ToolId("/no/such/tool") == "/no/such/tool");
  assert(store.Key("-std=c++23") == "-std=c++23");
  assert(store.Key(".") == ".");
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
  assert(!jig::ValidateManifest(offline, key, manifest.text));
  std::filesystem::remove_all(dir);
}

void TestDriver() {
  const jig::DriverConf conf = jig::ParseDriverConf(
      "cc = /seed/bin/clang\nflags = --target=x -O2\ncxxflags = -stdlib=libc++\n# comment\nlibc = /sr/libc\ncrt = "
      "/cc/lib/crt_interp.o\nruntimes = /sr/rt/lib\n");
  assert(conf.present && conf.cc == "/seed/bin/clang" && conf.flags == V({"--target=x", "-O2"}));
  const std::string store = jig::Store::Get().dir();

  // compile: conf flags, no link policy
  std::vector<std::string> out = jig::BuildDriverArgs(conf, jig::Language::kC, V({"-c", "a.c"}));
  assert(out == V({"--start-no-unused-arguments", "--target=x", "-O2", "--end-no-unused-arguments", "-c", "a.c"}));

  // C++ name adds driver mode + cxxflags
  out = jig::BuildDriverArgs(conf, jig::Language::kCxx, V({"-c", "a.cc"}));
  assert(out.at(3) == "--driver-mode=g++" && out.at(4) == "-stdlib=libc++");

  // executable link: rpath (runtime only for C++), interp stub, host rpaths dropped, foreign --dynamic-linker dropped
  out =
      jig::BuildDriverArgs(conf, jig::Language::kC,
                           V({"-o", "x", "x.c", "-Wl,-rpath,/usr/lib:/build/lib", "-Wl,--dynamic-linker=/lib/ld.so"}));
  const std::string joined = jig::Join(out, " ");
  assert(!joined.contains("/usr/lib"));
  assert(!joined.contains("/lib/ld.so "));
  assert(joined.contains("-Wl,-rpath,/build/lib:/sr/libc/lib/.:/_"));
  // cmake links with "-rpath,<build>:" and its install step insists on finding "<build>:" verbatim
  out = jig::BuildDriverArgs(conf, jig::Language::kC, V({"-o", "x", "x.c", "-Wl,-rpath,/build/build:"}));
  assert(jig::Join(out, " ").contains("-Wl,-rpath,/build/build::/sr/libc/lib/.:/_"));
  assert(!joined.contains("/sr/rt/lib"));
  assert(joined.contains(
      "-x none /cc/lib/crt_interp.o -Wl,--dynamic-linker=/sr/libc/lib/././././././././././././ld-linux-x86-64.so.2 "
      "-Wl,--export-dynamic-symbol=__reloc_start"));

  out = jig::BuildDriverArgs(conf, jig::Language::kCxx, V({"-o", "x", "x.cc"}));
  assert(jig::Join(out, " ").contains("/sr/rt/lib/.:/sr/libc/lib/.:/_"));
  out = jig::BuildDriverArgs(conf, jig::Language::kC, V({"-o", "x", "x.c", "-lc++"}));
  assert(jig::Join(out, " ").contains("/sr/rt/lib/.:/sr/libc/lib/.:/_"));

  // shared: rpath but no interp. Static / -r / -nostartfiles: nothing
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
  assert(!inv.links && inv.lib_dirs == V({"/b/deps"}));
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
  assert(inv.cacheable && inv.links && inv.lib_dirs == V({"/b/build/x/out"}));
  assert(std::ranges::contains(inv.key_args, "-C=linker=clang"));
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

void TestElfImage() {
  constexpr size_t kEhdrSize = 64;
  std::string bytes(kEhdrSize, '\0');
  constexpr std::string_view kMagic =
      "\x7f"
      "ELF\x02\x01";
  bytes.replace(0, kMagic.size(), kMagic);
  jig::ElfImage elf(bytes);
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
  assert(!jig::ElfImage("short").IsElf64LittleEndian());
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
  TestBase();
  TestStore();
  TestParseInvocation();
  TestParsePch();
  TestParsePreprocess();
  TestParseLink();
  TestParseJoinedOutput();
  TestResponseFiles();
  TestDepfile();
  TestManifest();
  TestDriver();
  TestDepInfo();
  TestRustInvocation();
  TestGoCache();
  TestElfImage();
  TestNixStore();
  std::println("jig_test: ok");
  return 0;
}
