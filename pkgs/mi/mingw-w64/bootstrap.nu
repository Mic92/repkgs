# mingw-w64 headers, crt and winpthreads via their configure/make, as llvm-mingw builds them.
# With $env.headersOnly it stops after the headers (compiler-rt needs them first).
use ../../../bootstrap/lib.nu *

const BINUTILS = {AR: "llvm-ar", RANLIB: "llvm-ranlib", DLLTOOL: "llvm-dlltool", NM: "llvm-nm", OBJCOPY: "llvm-objcopy", STRIP: "llvm-strip", RC: "llvm-windres", WINDRES: "llvm-windres"}

def configure-make [src: string, sub: string, args: list<string>, vars: record]: nothing -> nothing {
  let build = $"($env.NIX_BUILD_TOP)/build-($sub | str replace -a / -)"
  mkdir $build
  cd $build
  let sh = (tool sh)
  with-env ({CONFIG_SHELL: $sh} | merge $BINUTILS | merge $vars) {
    x sh $"($src)/($sub)/configure" $"--prefix=($env.out)" $"--host=($env.clangTarget)" --build=x86_64-build-linux-gnu --disable-dependency-tracking ...$args
    x make -j (cores | into string) $"SHELL=($sh)"
    x make install $"SHELL=($sh)"
  }
}

def main []: nothing -> nothing {
  let out = $env.out
  let src = (unpack mingw-w64)
  configure-make $src mingw-w64-headers [--enable-idl --with-default-msvcrt=ucrt --with-default-win32-winnt=0x0A00] {}
  cc-facts $out {include-dirs: [include]}
  if "headersOnly" in $env { return }

  let rt = $env."compiler-rt"
  let cc = $"clang (target | str join ' ') -resource-dir=($rt) -isystem ($out)/include --start-no-unused-arguments -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld -L($out)/lib --end-no-unused-arguments"
  let libdir = (if $env.cpu == "aarch64" { [--disable-lib32 --disable-lib64 --enable-libarm64] } else { [--disable-lib32 --enable-lib64] })
  configure-make $src mingw-w64-crt ($libdir ++ [--with-default-msvcrt=ucrt --enable-cfguard]) {CC: $cc, CCAS: $cc, CPPFLAGS: $"-I($out)/include"}
  # clang adds -lssp -lssp_nonshared for -fstack-protector, mingw-w64 has that in libmingwex
  for l in [ssp ssp_nonshared] { x llvm-ar rcs $"($out)/lib/lib($l).a" }
  # Rust's std imports combase.dll by name (raw-dylib), mingw-w64 ships its .def for arm32 only
  let m = ({x86_64: "i386:x86-64", aarch64: arm64} | get $env.cpu)
  x llvm-dlltool -m $m -d $"($src)/mingw-w64-crt/libarm32/combase.def" -l $"($out)/lib/libcombase.a"
  configure-make $src mingw-w64-libraries/winpthreads [--enable-static --enable-shared] {CC: $cc, CPPFLAGS: $"-I($out)/include", RCFLAGS: $"-I($out)/include", LDFLAGS: $"-L($out)/lib"}
  note mingw-w64 $"(ls $'($out)/lib' | length) files in lib/"
}
