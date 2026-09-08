# glibc via its own configure/make under stage0 dash + make, compiled by the seed clang with this
# platform's compiler-rt. With $env.headersOnly it stops after install-headers (compiler-rt needs
# libc headers before libc can be linked against compiler-rt).
use ../../../bootstrap/lib.nu *

def configure [src: path, out: path]: nothing -> string {
  (x sh $"($src)/configure" $"--prefix=($out)" $"--host=($env.triple)" --build=x86_64-build-linux-gnu
    $"--with-headers=($env.linuxHeaders)/include" --enable-kernel=5.10 --disable-werror --disable-nscd
    --enable-bind-now --enable-fortify-source --enable-stack-protector=strong
    $"libc_cv_slibdir=($out)/lib" $"libc_cv_rtlddir=($out)/lib"
    ...($env.configureFlags | split row " " | where { $in != "" }))
}

def main []: nothing -> nothing {
  let out = $env.out
  let src = (unpack glibc)
  cd $src
  for p in ($env.patches | split row " ") { x patch -p1 -i $p }
  let build = $"($env.NIX_BUILD_TOP)/build"
  mkdir $build
  cd $build

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
  let make = [-j (cores | into string) $"SHELL=($sh)" $"sysincludes=($sysincludes)"]
  if "headersOnly" in $env {
    x make ...$make install-headers
    touch $"($out)/include/gnu/stubs.h"
    return
  }
  let mlog = $"($env.NIX_BUILD_TOP)/make.log"
  let ok = (try { ^make ...$make o+e> $mlog; true } catch { false })
  if not $ok {
    # parallel make buries the failing command. Compile lines are noise, the rest is context
    print -e (open --raw $mlog | lines | where { $in !~ 'reassign symbol|static-libgcc| -c ' } | last 200 | str join "\n")
    error make {msg: "glibc make failed"}
  }
  # serial: parallel install races on the .dt -> .d depfile conversion (several sub-makes include
  # the same sysd-rules and each `mv`s the same files) Nothing is compiled here anyway
  x make ...$make install -j1
  say $"glibc ($env.cpu): (ls $'($out)/lib' | length) files in lib/"
}
