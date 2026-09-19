#!/usr/bin/env nu
# The VC++ redistributable DLLs (vcruntime140, msvcp140) as their own small store path: sysroot
# bin/, what an msvc binary's launcher names at run time, without the SDK behind it
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  mkdir $"($env.out)/bin"
  cp ...(files $"($env.sdk)/crt/redist/*.dll") $"($env.out)/bin/"
}
