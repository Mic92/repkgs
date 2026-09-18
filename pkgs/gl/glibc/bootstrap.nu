# glibc via its own configure/make under the seed's dash + make, compiled by clang with this
# platform's compiler-rt. With $env.headersOnly it stops after install-headers (compiler-rt needs
# libc headers before libc can be linked against compiler-rt).
use ../../../bootstrap/lib.nu *

# per-cpu configure arguments: probes that cannot run when cross compiling, ABI choices, and
# checks for GCC-only flags clang does not need (upstream-ppc64le-clang.patch)
const CPU_FLAGS = {
  x86_64: [--enable-cet libc_cv_have_x86_lahf_sahf=yes libc_cv_have_x86_movbe=yes]
  # power9: preconfigure reads the cpu from GCC's `.machine`. No fortify: libc lacks the ieee128
  # __vasprintf_chk clang's wrapper calls. mlong_double_128: the probe is a nested function
  powerpc64le: [--with-cpu=power9 --enable-fortify-source=no libc_cv_no_gnu_attr_ok=yes libc_cv_mlong_double_128=yes]
}

const BINUTILS = {LD: "ld.lld", AR: "llvm-ar", NM: "llvm-nm", OBJCOPY: "llvm-objcopy", OBJDUMP: "llvm-objdump", READELF: "llvm-readelf", STRIP: "llvm-strip"}

# A constant prefix compiled in: the output's bytes must not depend on $out (lld orders merged
# strings by content hash, so a CA rebuild under another scratch path would differ).
# glibc-prefix-relative.patch finds the data directories from the loaded libc.so instead. This
# path never exists at run time. Not builder/prepare.nu's /build/prefix: libc.a carries the
# literal into every static binary, where finish would take it for an unrelocated install path
const PREFIX = "/build/glibc"

def patched-source []: nothing -> path {
  let src = (unpack glibc)
  cd $src
  for p in ($env.patches | split row " ") { x patch -p1 -i $p }
  # GCC-only asm constraints (an int as "=f", a 128-bit float as "+frm"/"+dwa"): generic versions
  if $env.cpu == "loongarch64" {
    rm ...(^grep -rl '"=f" (\(x_cond\|fn_cond\|cls\))' sysdeps/loongarch | lines)
  }
  rm -f sysdeps/loongarch/fpu/math-barriers.h sysdeps/powerpc/fpu/math-barriers.h
  $src
}

# CXX=false: a working c++ would make the build compile a C++ test helper against our headers.
# The link flags sit in no-unused-arguments because configure probes with `-Werror -S`
def configure [src: path, rt: string, sh: path]: nothing -> nothing {
  let cc = $"clang (target | str join ' ') -resource-dir=($rt) --start-no-unused-arguments -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld --end-no-unused-arguments"
  let vars = {CONFIG_SHELL: $sh, CC: $cc, CXX: "false", BUILD_CC: "cc", LDFLAGS: $"-L($rt)/lib/($env.clangTarget)"} | merge $BINUTILS
  "with-clang = yes\n" | save configparms # sysdeps Makefiles branch on it
  with-env $vars {
    (x sh $"($src)/configure" $"--prefix=($PREFIX)" --sysconfdir=/etc $"--host=($env.clangTarget)" --build=x86_64-build-linux-gnu
      $"--with-headers=($env.linuxHeaders)/include" --enable-kernel=5.10 --disable-werror --disable-nscd
      --enable-bind-now --enable-fortify-source --enable-stack-protector=strong
      $"libc_cv_slibdir=($PREFIX)/lib" $"libc_cv_rtlddir=($PREFIX)/lib"
      ...($CPU_FLAGS | get -o $env.cpu | default []))
  }
}

# `make install` went to DESTDIR/PREFIX: that tree becomes $out. The shell scripts (ldd, sotruss,
# xtrace, tzselect) and the libc.so/libm.so linker scripts name PREFIX: relative to the script,
# and bare library names the linker looks up next to the script
def install-tree [dest: path, out: path]: nothing -> nothing {
  mkdir $out
  for f in (ls -a $"($dest)($PREFIX)" | get name) { mv $f $out }
  for f in (files $"($out)/bin/{ldd,sotruss,xtrace,tzselect}") {
    let text = (open --raw $f)
    $text | str replace -a $PREFIX '${0%/*}/..' | save -f $f
  }
  for f in (files $"($out)/lib/lib{c,m}.{so,a}") {
    let text = (open --raw $f | into binary)
    if ($text | bytes starts-with ("/* GNU ld script" | into binary)) {
      $text | decode | str replace -a $"($PREFIX)/lib/" "" | save -f $f
    }
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
  # the headers-only pass runs before compiler-rt exists: the compiler's resource dir has the headers
  let rt = ($env."compiler-rt"? | default { ^clang --print-resource-dir | str trim })
  let sh = (tool sh)
  mkdir $"($env.NIX_BUILD_TOP)/build"
  cd $"($env.NIX_BUILD_TOP)/build"
  configure $src $rt $sh

  # sysincludes: configure derives it from a GCC layout. gnulib-extralibdir: Makeconfig otherwise
  # runs `$(CC) -print-file-name=libgcc_s.so.1` ~600 times for an empty answer. zonedir: the time
  # zone database is the machine's and updated apart from libc (glibc-tzdir-etc-zoneinfo.patch)
  let make = [-j (cores | into string) $"SHELL=($sh)"
    $"sysincludes=-nostdinc -isystem ($rt)/include -isystem ($env.linuxHeaders)/include"
    "gnulib-extralibdir=" "zonedir=/usr/share/zoneinfo"]
  let dest = $"($env.NIX_BUILD_TOP)/dest"
  if "headersOnly" in $env {
    x make ...$make install-headers $"DESTDIR=($dest)"
    install-tree $dest $out
    touch $"($out)/include/gnu/stubs.h"
  } else {
    x make ...$make
    x make ...$make install -j1 $"DESTDIR=($dest)" # parallel install races on the .dt -> .d depfile moves
    install-tree $dest $out
    if $env.locale == "true" { c-utf8-locale $src $out }
  }
  cc-facts $out {include-dirs: [include]}
}
