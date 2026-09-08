# What `clang --sysroot` expects: {usr/,}include, {usr/,}lib{,64}, resource dir under lib/clang.
# $env.parts (libc, linux-headers, runtimes, ...) are merged as symlink trees. Later parts win
# (musl and the kernel both ship include/scsi).
use lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  mkdir $"($out)/include" $"($out)/lib/clang/lib"
  x ln -s . $"($out)/usr"
  x ln -s lib $"($out)/lib64"
  for p in ($env.parts | split row " ") {
    for d in [include lib] {
      if ($"($p)/($d)" | path exists) { x cp -rsf $"($p)/($d)/." $"($out)/($d)/" }
    }
  }
  x ln -s $"($env.resource)/include" $"($out)/lib/clang/include"
  x ln -s $"($env.resource)/lib/($env.triple)" $"($out)/lib/clang/lib/($env.triple)"
  # depfiles name the symlink targets. The compile cache needs to know them (lib.nu JIG_STORE_ROOTS)
  $"($env.parts) ($env.resource)
" | save $"($out)/roots"
  # glibc installs libc.so/libm.{so,a} as linker scripts naming absolute paths, which defeats
  # --sysroot and relocation. Bare names are looked up in -L dirs
  for f in (glob $"($out)/lib/lib{c,m}.{so,a}") {
    # libc.a is a real archive (valid UTF-8 with "GROUP" somewhere inside): only touch ld scripts
    if (open --raw $f | into binary | bytes starts-with ("/* GNU ld script" | into binary)) {
      let text = (open --raw $f | decode utf-8)
      rm $f
      $text | str replace -ar $"($env.NIX_STORE)/[^ \)]*/" "" | save $f
    }
  }
}
