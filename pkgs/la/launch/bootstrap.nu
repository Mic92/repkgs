#!/usr/bin/env nu
# docs/design.md §3 launcher as its own store path: packages symlink bin/<x> -> ../../<this>/bin/launch.
# static-pie so it has no interpreter or RUNPATH of its own to relocate.
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  let jsn = $"($env.NIX_BUILD_TOP)/json"
  mkdir $jsn $"($out)/bin"
  cp $env.json_hpp $"($jsn)/json.hpp"
  (x c++ -std=c++23 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -static-pie
    -isystem $jsn -o $"($out)/bin/launch" $env.launch)
  x llvm-strip --strip-all $"($out)/bin/launch"
  say $"launch: (ls $"($out)/bin/launch" | first | get size)"
}
