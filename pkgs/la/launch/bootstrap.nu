#!/usr/bin/env nu
# docs/design.md §3 launcher as its own store path: bin/<x> symlinks to (ELF) or is a copy of (PE)
# bin/launch. static(-pie) so it has nothing of its own to relocate (no static PIE on powerpc64)
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  let jsn = $"($env.NIX_BUILD_TOP)/json"
  mkdir $jsn $"($out)/bin"
  cp $env.json_hpp $"($jsn)/json.hpp"
  let windows = ($env.os == "windows")
  let static = (if $windows or $env.cpu == "powerpc64le" { "-static" } else { "-static-pie" })
  let exe = $"($out)/bin/launch(if $windows { '.exe' })"
  (x c++ -std=c++23 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti $static
    -isystem $jsn -o $exe $env.launch)
  x llvm-strip --strip-all $exe
  note launch $"(ls $exe | first | get size)"
}
