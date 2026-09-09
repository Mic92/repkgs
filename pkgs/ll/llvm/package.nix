# LLVM as a library: libLLVM.so, headers, llvm-config and the object tools, from the same pin the
# toolchain is built from. For rustc (and later zig) to link against. clang and lld stay in `cc`.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "llvm";
  uses = [ "cmake" ];
  cmake.root = "llvm";
  cmake.defs = import ./defs.nix;
  dependencies = [
    pkgs.zlib
    pkgs.zstd
  ];
  buildDependencies = [ buildPkgs.cpython ];
  tests.run = false; # LLVM_INCLUDE_TESTS off: hours
  bin = [ "llvm-config" ];
}
