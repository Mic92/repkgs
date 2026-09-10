#!/usr/bin/env nu
# lib/dlaudit.so: the rtld-audit module finish.nu runs the version check under (LD_AUDIT), so a
# dlopen of something outside the closure fails the build instead of some code path at run time.
# Header-only C++ (string_view, array) and -nostdlib++: nothing but libc in the audited process
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  mkdir $"($env.out)/lib"
  (x c++ -std=c++23 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -shared -fPIC -nostdlib++
    -o $"($env.out)/lib/dlaudit.so" $env.dlaudit)
}
