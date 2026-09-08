# Kernel UAPI headers via the kernel's own `make headers` (needs make, sh, sed and a host cc).
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  cd (unpack linux)
  # HOSTCC builds unifdef & co. for the build machine: stage0's cc in stage1, the seed clang in stage0
  let hostcc = (if (which cc | is-not-empty) { "cc" } else { [clang] ++ (ccflags) ++ [-static-pie] | str join " " })
  let sh = (tool sh)
  x make -j (cores | into string) headers $"ARCH=($env.karch)" $"HOSTCC=($hostcc)" $"SHELL=($sh)" $"CONFIG_SHELL=($sh)"
  copy-tree usr/include $"($out)/include" "**/*.h"   # = `make headers_install` without rsync
  say $"linux-headers: (glob $'($out)/include/**/*.h' | length) headers"
}
