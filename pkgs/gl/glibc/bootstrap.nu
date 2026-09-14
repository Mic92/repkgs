# glibc via its own configure/make under stage0 dash + make, compiled by the seed clang with this
# platform's compiler-rt. With $env.headersOnly it stops after install-headers (compiler-rt needs
# libc headers before libc can be linked against compiler-rt).
use ../../../bootstrap/lib.nu *

# per-cpu configure arguments: probes that cannot run when cross compiling, ABI choices, and
# checks for GCC-only flags clang does not need (upstream-ppc64le-clang.patch)
const CPU_FLAGS = {
  x86_64: [--enable-cet libc_cv_have_x86_lahf_sahf=yes libc_cv_have_x86_movbe=yes]
  # ldbl-opt's -mlong-double-128 probe is written as a nested function, a GCC extension
  powerpc64le: [--with-long-double-format=ieee libc_cv_no_gnu_attr_ok=yes libc_cv_mlong_double_128=yes]
}

const BINUTILS = {LD: "ld.lld", AR: "llvm-ar", NM: "llvm-nm", OBJCOPY: "llvm-objcopy", OBJDUMP: "llvm-objdump", READELF: "llvm-readelf", STRIP: "llvm-strip"}

def patched-source []: nothing -> path {
  let src = (unpack glibc)
  cd $src
  for p in ($env.patches | split row " ") { x patch -p1 -i $p }
  # fclass.{s,d} asm with an int as "=f" output, GCC only: the generic C versions take over
  if $env.cpu == "loongarch64" {
    rm ...(^grep -rl '"=f" (\(x_cond\|fn_cond\|cls\))' sysdeps/loongarch | lines)
  }
  $src
}

# CXX=false: a working c++ would make the build compile a C++ test helper against our headers.
# The link flags sit in no-unused-arguments because configure probes with `-Werror -S`
def configure [src: path, rt: string, sh: path]: nothing -> nothing {
  let cc = $"clang (target | str join ' ') -resource-dir=($rt) --start-no-unused-arguments -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld --end-no-unused-arguments"
  let vars = {CONFIG_SHELL: $sh, CC: $cc, CXX: "false", BUILD_CC: "cc", LDFLAGS: $"-L($rt)/lib/($env.triple)"} | merge $BINUTILS
  "with-clang = yes\n" | save configparms # sysdeps Makefiles branch on it
  with-env $vars {
    (x sh $"($src)/configure" $"--prefix=($env.out)" $"--host=($env.triple)" --build=x86_64-build-linux-gnu
      $"--with-headers=($env.linuxHeaders)/include" --enable-kernel=5.10 --disable-werror --disable-nscd
      --enable-bind-now --enable-fortify-source --enable-stack-protector=strong
      $"libc_cv_slibdir=($env.out)/lib" $"libc_cv_rtlddir=($env.out)/lib"
      ...($CPU_FLAGS | get -o $env.cpu | default []))
  }
}

# C.UTF-8 so LC_ALL=C.UTF-8 works without a locales package (~360 K), compiled by the fresh localedef
def c-utf8-locale [src: path, out: path]: nothing -> nothing {
  mkdir $"($out)/lib/locale"
  with-env {I18NPATH: $"($src)/localedata"} {
    x $"($out)/lib/($env.interp)" --library-path $"($out)/lib" $"($out)/bin/localedef" --no-archive -i C -f UTF-8 $"($out)/lib/locale/C.utf8"
  }
}

def main []: nothing -> nothing {
  let out = $env.out
  let src = (patched-source)
  # the headers-only pass runs before compiler-rt exists: the seed's resource dir has the headers
  let rt = ($env."compiler-rt"? | default { ^clang --print-resource-dir | str trim })
  let sh = (tool sh)
  mkdir $"($env.NIX_BUILD_TOP)/build"
  cd $"($env.NIX_BUILD_TOP)/build"
  configure $src $rt $sh

  # sysincludes: configure derives it from a GCC layout. gnulib-extralibdir: Makeconfig otherwise
  # runs `$(CC) -print-file-name=libgcc_s.so.1` ~600 times for an empty answer
  let make = [-j (cores | into string) $"SHELL=($sh)"
    $"sysincludes=-nostdinc -isystem ($rt)/include -isystem ($env.linuxHeaders)/include"
    "gnulib-extralibdir="]
  cc-facts $out {include-dirs: [include]}
  if "headersOnly" in $env {
    x make ...$make install-headers
    touch $"($out)/include/gnu/stubs.h"
  } else {
    x make ...$make
    x make ...$make install -j1 # parallel install races on the .dt -> .d depfile moves
    if $env.locale == "true" { c-utf8-locale $src $out }
  }
}
