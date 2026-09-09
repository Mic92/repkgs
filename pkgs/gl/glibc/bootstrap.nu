# glibc via its own configure/make under stage0 dash + make, compiled by the seed clang with this
# platform's compiler-rt. With $env.headersOnly it stops after install-headers (compiler-rt needs
# libc headers before libc can be linked against compiler-rt).
use ../../../bootstrap/lib.nu *

# per-cpu configure arguments: probes that cannot run when cross compiling, ABI choices, and
# checks for GCC-only flags clang does not need (glibc-ppc64le-clang.patch)
const CPU_FLAGS = {
  x86_64: [libc_cv_have_x86_lahf_sahf=yes libc_cv_have_x86_movbe=yes]
  # ldbl-opt's -mlong-double-128 probe is written as a nested function, a GCC extension
  powerpc64le: [--with-long-double-format=ieee libc_cv_no_gnu_attr_ok=yes libc_cv_mlong_double_128=yes]
}

def configure [src: path, out: path]: nothing -> nothing {
  (x sh $"($src)/configure" $"--prefix=($out)" $"--host=($env.triple)" --build=x86_64-build-linux-gnu
    $"--with-headers=($env.linuxHeaders)/include" --enable-kernel=5.10 --disable-werror --disable-nscd
    --enable-bind-now --enable-fortify-source --enable-stack-protector=strong
    $"libc_cv_slibdir=($out)/lib" $"libc_cv_rtlddir=($out)/lib"
    ...($CPU_FLAGS | get -o $env.cpu | default []))
}

def main []: nothing -> nothing {
  let out = $env.out
  let src = (unpack glibc)
  cd $src
  for p in ($env.patches | split row " ") { x patch -p1 -i $p }
  let build = $"($env.NIX_BUILD_TOP)/build"
  mkdir $build
  cd $build
  "with-clang = yes\n" | save configparms  # read by Makeconfig; sysdeps Makefiles branch on it

  # the headers-only pass has no compiler-rt yet. The seed's resource dir (headers only) suffices
  let rt = (if "compiler-rt" in $env { $env."compiler-rt" } else { ^clang --print-resource-dir | str trim })
  let sysincludes = $"-nostdinc -isystem ($rt)/include -isystem ($env.linuxHeaders)/include"
  # configure probes with `-Werror -S`, so link-only flags must not warn
  let cc = ([clang] ++ (target) ++ [$"-resource-dir=($rt)" --start-no-unused-arguments -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld --end-no-unused-arguments] | str join " ")
  let binutils = {LD: "ld.lld", AR: "llvm-ar", NM: "llvm-nm", OBJCOPY: "llvm-objcopy", OBJDUMP: "llvm-objdump", READELF: "llvm-readelf", STRIP: "llvm-strip"}

  # CXX=false: a working c++ would make the build compile a C++ test helper against our headers
  let sh = (tool sh)
  with-env ({SHELL: $sh, CONFIG_SHELL: $sh, CC: $cc, CXX: "false", BUILD_CC: "cc", LDFLAGS: $"-fuse-ld=lld -L($rt)/lib/($env.triple)"} | merge $binutils) {
    try { configure $src $out } catch {|e|
      print -e (open --raw config.log | lines | where { $in =~ '(?i)error|configure:[0-9]+: (checking|result)|^[/a-z].*clang ' } | last 40 | str join "\n")
      error make {msg: $e.msg}
    }
  }
  # gnulib-extralibdir: Makeconfig's lazy `$(shell $(CC) -print-file-name=libgcc_s.so.1)`,
  # expanded ~600 times per build. There is no libgcc_s here (compiler-rt), the answer is empty
  let make = [-j (cores | into string) $"SHELL=($sh)" $"sysincludes=($sysincludes)" "gnulib-extralibdir="]
  # glibc's make output is ~10k lines of compile commands and "overriding recipe" warnings: to a
  # file, the tail minus noise on failure
  let mlog = $"($env.NIX_BUILD_TOP)/make.log"
  def --wrapped make-logged [...args: string]: nothing -> nothing {
    print -e $"+ make ($args | str join ' ') > make.log"
    let ok = (try { ^make ...$args o+e>> $mlog; true } catch { false })
    if not $ok {
      # parallel make buries the failing command: every error line, then the tail for context
      let ls = (open --raw $mlog | lines)
      print -e ($ls | where { $in =~ '(?i)error|\*\*\*' and $in !~ 'Werror|-Wno-error' } | append ($ls | where { $in !~ 'reassign symbol|static-libgcc|overriding recipe|ignoring old recipe| -c ' } | last 100) | str join "\n")
      error make {msg: $"glibc: make ($args | last) failed"}
    }
  }
  if "headersOnly" in $env {
    make-logged ...$make install-headers
    touch $"($out)/include/gnu/stubs.h"
    return
  }
  make-logged ...$make
  # serial: parallel install races on the .dt -> .d depfile conversion (several sub-makes include
  # the same sysd-rules and each `mv`s the same files) Nothing is compiled here anyway
  make-logged ...$make install -j1
  # C.UTF-8 so LC_ALL=C.UTF-8 works everywhere without a locales package (charmap data only, ~360 K)
  if $env.locale == "true" {
    mkdir $"($out)/lib/locale"
    with-env {I18NPATH: $"($src)/localedata"} {
      x $"($out)/lib/($env.interp)" --library-path $"($out)/lib" $"($out)/bin/localedef" --no-archive -i C -f UTF-8 $"($out)/lib/locale/C.utf8"
    }
  }
  say $"glibc ($env.cpu): (ls $'($out)/lib' | length) files in lib/"
}
