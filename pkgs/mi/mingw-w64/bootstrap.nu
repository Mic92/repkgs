# mingw-w64 headers + CRT (the Windows "libc": import libs for ucrt/kernel32 & co. and the
# startup objects) via its own configure/make, compiled by the seed clang for <cpu>-w64-mingw32.
# With $env.headersOnly it stops after the headers (compiler-rt needs them first).
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  let src = (unpack mingw-w64)
  let sh = (tool sh)
  let jobs = [-j (cores | into string) $"SHELL=($sh)"]
  let common = [$"--prefix=($out)" $"--host=($env.triple)" --build=x86_64-build-linux-gnu --with-default-msvcrt=ucrt]

  mkdir $"($env.NIX_BUILD_TOP)/headers"
  cd $"($env.NIX_BUILD_TOP)/headers"
  with-env {SHELL: $sh, CONFIG_SHELL: $sh} {
    x sh $"($src)/mingw-w64-headers/configure" ...$common --enable-idl --with-default-win32-winnt=0x0A00
  }
  x make ...$jobs install
  if "headersOnly" in $env { say $"mingw-w64: (glob $'($out)/include/**/*.h' | length) headers"; return }

  # the CRT is C + asm only; dlltool/windres are llvm's
  let rt = $env."compiler-rt"
  let cc = ([clang] ++ (target) ++ [$"-resource-dir=($rt)" -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld $"-isystem($out)/include"] | str join " ")
  # llvm-dlltool has no default machine; the Makefile also runs $(DLLTOOL) $(AM_DLLTOOLFLAGS) with --as=$(AS)
  let machine = (match $env.cpu { "x86_64" => "i386:x86-64", "aarch64" => "arm64", _ => $env.cpu })
  let binutils = {AR: "llvm-ar", RANLIB: "llvm-ranlib", DLLTOOL: $"llvm-dlltool -m ($machine)", NM: "llvm-nm", OBJCOPY: "llvm-objcopy", STRIP: "llvm-strip", RC: "llvm-windres", WINDRES: "llvm-windres", CCAS: $cc}
  let libflags = (match $env.cpu { "x86_64" => [--enable-lib64 --disable-lib32], "aarch64" => [--enable-libarm64 --disable-lib32 --disable-lib64], _ => [] })
  mkdir $"($env.NIX_BUILD_TOP)/crt"
  cd $"($env.NIX_BUILD_TOP)/crt"
  with-env ({SHELL: $sh, CONFIG_SHELL: $sh, CC: $cc, CPP: $"($cc) -E"} | merge $binutils) {
    x sh $"($src)/mingw-w64-crt/configure" ...$common $"--with-sysroot=($out)" --enable-wildcard ...$libflags
  }
  x make ...$jobs
  x make ...$jobs install
  # clang's mingw driver looks in <sysroot>/lib and <sysroot>/<triple>/lib; keep one flat lib/
  say $"mingw-w64: (glob $'($out)/lib/*.a' | length) import/static libs"
}
