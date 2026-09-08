# musl with nu + clang directly (its configure/Makefile need sh and make, which do not exist yet).
# Mirrors musl's Makefile: generated headers, arch overrides, per-file flag classes.
# With $env.headersOnly it stops after the headers (compiler-rt needs them before libc.so can link).
use ../../../bootstrap/lib.nu *

# Port of tools/mkalltypes.sed.
def mkalltypes [files: list<path>]: nothing -> string {
  let guard = {|kind, name, decl| $"#if defined\(__NEED_($kind)($name)\) && !defined\(__DEFINED_($kind)($name)\)\n($decl)\n#define __DEFINED_($kind)($name)\n#endif\n" }
  $files | each { open --raw $in } | str join | lines | each {|l|
    let t = ($l | parse -r '^TYPEDEF (?<def>.*) (?<name>[^ ]*);$')
    let s = ($l | parse -r '^STRUCT * (?<name>[^ ]*) (?<def>.*);$')
    let u = ($l | parse -r '^UNION * (?<name>[^ ]*) (?<def>.*);$')
    if ($t | is-not-empty) { do $guard "" $t.0.name $"typedef ($t.0.def) ($t.0.name);"
    } else if ($s | is-not-empty) { do $guard "struct_" $s.0.name $"struct ($s.0.name) ($s.0.def);"
    } else if ($u | is-not-empty) { do $guard "union_" $u.0.name $"union ($u.0.name) ($u.0.def);"
    } else { $l }
  } | str join "\n" | $in + "\n"
}

def headers [src: path, inc: path]: nothing -> nothing {
  let arch = $env.cpu
  copy-tree $"($src)/include" $inc "**/*.h"
  copy-tree $"($src)/arch/generic/bits" $"($inc)/bits" "*.h"
  copy-tree $"($src)/arch/($arch)/bits" $"($inc)/bits" "*.h"
  mkalltypes [$"($src)/arch/($arch)/bits/alltypes.h.in" $"($src)/include/alltypes.h.in"] | save -f $"($inc)/bits/alltypes.h"
  let sc = (open --raw $"($src)/arch/($arch)/bits/syscall.h.in")
  $sc + ($sc | lines | where { str contains "__NR_" } | each { str replace "__NR_" "SYS_" } | str join "\n") + "\n" | save -f $"($inc)/bits/syscall.h"
}

def stem-path [f: string]: nothing -> string { $f | path dirname | path join ($f | path parse | get stem) }

# Source set as the Makefile computes it: <dir>/*.c, where <dir>/<cpu>/*.[csS] replaces the same stem.
def sources [src: path, arch: string]: nothing -> list<string> {
  let dirs = (glob $"($src)/src/*" | where { ($in | path type) == "dir" }) ++ [$"($src)/src/malloc/mallocng" $"($src)/crt" $"($src)/ldso"]
  let generic = ($dirs | each {|d| glob $"($d)/*.c" } | flatten)
  let specific = ($dirs | each {|d| glob $"($d)/($arch)/*.{c,s,S}" } | flatten)
  let overridden = ($specific | each {|f| stem-path ($f | path dirname | path dirname | path join ($f | path basename)) })
  ($generic | where { (stem-path $in) not-in $overridden }) ++ $specific | sort
}

# Per-file flag classes from the Makefile (OPTIMIZE_GLOBS, MEMOPS, NOSSP, CRT).
def file-flags [rel: string]: nothing -> list<string> {
  let stem = ($rel | path parse | get stem)
  let kind = ($rel | path split | first)          # src | crt | ldso
  let subdir = ($rel | path split | skip 1 | first)
  [
    (if $subdir in [internal malloc string] { [-O3] })
    (if $stem in [memcpy memmove memcmp memset] { [-fno-builtin] })
    (if $kind == "crt" { [-DCRT] })
    (if $kind != "src" or $stem in [__libc_start_main __init_tls __stack_chk_fail __set_thread_area memset memcpy] { [-fno-stack-protector] })
    (if $stem in [Scrt1 rcrt1] { [-fPIC] })
  ] | compact | flatten
}

def main []: nothing -> nothing {
  let out = $env.out
  let arch = $env.cpu
  let src = (unpack musl)
  let obj = $"($env.NIX_BUILD_TOP)/obj"
  headers $src $"($out)/include"
  if "headersOnly" in $env { return }
  mkdir $"($obj)/src/internal"
  $"#define VERSION \"(open --raw $'($src)/VERSION' | str trim)\"\n" | save -f $"($obj)/src/internal/version.h"

  # what musl's configure picks for clang. -nostdinc: musl brings its own stdarg/stddef
  let common = (target) ++ [
    -std=c99 -nostdinc -ffreestanding -fexcess-precision=standard -frounding-math -fno-strict-aliasing "-Wa,--noexecstack"
    -D_XOPEN_SOURCE=700 $"-I($src)/arch/($arch)" $"-I($src)/arch/generic" $"-I($obj)/src/internal" $"-I($src)/src/include" $"-I($src)/src/internal" $"-I($out)/include"
    -O2 -pipe -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections -fPIC
    -w -Qunused-arguments -Werror=implicit-function-declaration -Werror=implicit-int -Werror=pointer-sign -Werror=pointer-arith -Werror=int-conversion -Werror=incompatible-pointer-types
  ]
  let items = (sources $src $arch | each {|s|
    let rel = ($s | path relative-to $src)
    {src: $s, rel: $rel, kind: ($rel | path split | first), flags: (file-flags $rel)}
  })
  say $"musl: ($items | where kind == src | length) libc sources, (cores) jobs"
  mkdir $"($out)/lib"
  # everything is -fPIC, so one object set serves libc.a and libc.so (musl's Makefile builds .o and .lo
  # separately only to allow a non-PIC static lib)
  let objs = (compile $common ($items | where kind == "src" | each {|i| $i | insert obj $"($obj)/($i.rel).o" }))
  let ldso = (compile $common ($items | where kind == "ldso" | each {|i| $i | insert obj $"($obj)/($i.rel).o" }))
  compile $common ($items | where kind == "crt" | each {|i| $i | insert obj $"($out)/lib/($i.src | path parse | get stem).o" })

  archive $"($out)/lib/libc.a" $objs
  for n in [m rt pthread crypt util xnet resolv dl] { x llvm-ar rcD $"($out)/lib/lib($n).a" }  # empty compat libs
  let rsp = $"($obj)/libc.so.rsp"
  $objs ++ $ldso | str join "\n" | save -f $rsp
  (x clang ...(target) -fuse-ld=lld -nostdlib -shared "-Wl,-e,_dlstart"
     "-Wl,--sort-section,alignment" "-Wl,--sort-common" "-Wl,--gc-sections" "-Wl,--hash-style=both" "-Wl,--no-undefined" "-Wl,--exclude-libs=ALL"
     $"-Wl,--dynamic-list=($src)/dynamic.list" -o $"($out)/lib/libc.so" $"@($rsp)"
     $"($env.'compiler-rt')/lib/($env.triple)/libclang_rt.builtins.a")
  x ln -s libc.so $"($out)/lib/ld-musl-($arch).so.1"
  say $"musl: (ls $'($out)/lib' | length) files in lib/"
}
