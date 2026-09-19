# What `clang --sysroot` / `-isysroot` expects: {usr/,}include, {usr/,}lib{,64}, and our
# compiler-rt as the resource dir under lib/clang. $env.parts (libc, linux-headers, runtimes, an
# SDK) are merged as symlink trees, later parts win (musl and the kernel both ship include/scsi).
use lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  mkdir $"($out)/include" $"($out)/lib"
  for p in ($env.parts | split row " ") { x cp -rsf $"($p)/." $"($out)/" }
  x cp -rs $env.resource $"($out)/lib/clang"
  # MacOSX.sdk brings a real usr/ (and the SDKSettings.json the darwin driver reads), ELF sysroots alias it
  if not ($"($out)/usr" | path exists) { x ln -s . $"($out)/usr" }
  x ln -s lib $"($out)/lib64"
  # tools copy `cc -print-file-name=crt*.o` verbatim (rust's self-contained/): no symlinks
  for o in (files $"($out)/lib/*crt*.o") { let t = ($o | path expand); rm $o; cp $t $o }
  # depfiles name the symlink targets. The compile cache needs to know them (lib.nu JIG_STORE_ROOTS)
  $"($env.parts) ($env.resource)\n" | save $"($out)/roots"
}
