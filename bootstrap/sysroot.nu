# What `clang --sysroot` / `-isysroot` expects: {usr/,}include, {usr/,}lib{,64}, and our
# compiler-rt as the resource dir under lib/clang. $env.parts (libc, linux-headers, runtimes, an
# SDK) are merged as symlink trees, later parts win (musl and the kernel both ship include/scsi).
use lib.nu *

# glibc installs libc.so/libm.{so,a} as linker scripts naming absolute paths, which defeats
# --sysroot and relocation. Bare names are looked up in -L dirs
def relativise-ld-scripts [libdir: string]: nothing -> nothing {
  for f in (glob $"($libdir)/lib{c,m}.{so,a}") {
    # libc.a is a real archive: only touch ld scripts
    if (open --raw $f | into binary | bytes starts-with ("/* GNU ld script" | into binary)) {
      let text = (open --raw $f | decode utf-8)
      rm $f
      $text | str replace -ar $"($env.NIX_STORE)/[^ \)]*/" "" | save $f
    }
  }
}

def main []: nothing -> nothing {
  let out = $env.out
  mkdir $"($out)/include" $"($out)/lib"
  for p in ($env.parts | split row " ") { x cp -rsf $"($p)/." $"($out)/" }
  x cp -rs $env.resource $"($out)/lib/clang"
  # MacOSX.sdk brings a real usr/ (and the SDKSettings.json the darwin driver reads), ELF sysroots alias it
  if not ($"($out)/usr" | path exists) { x ln -s . $"($out)/usr" }
  x ln -s lib $"($out)/lib64"
  relativise-ld-scripts $"($out)/lib"
  # depfiles name the symlink targets. The compile cache needs to know them (lib.nu JIG_STORE_ROOTS)
  $"($env.parts) ($env.resource)\n" | save $"($out)/roots"
}
