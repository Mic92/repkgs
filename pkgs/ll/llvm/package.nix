# LLVM as a library: libLLVM.so, headers, llvm-config and the object tools, from the same pin the
# toolchain is built from. For rustc (and later zig) to link against. clang and lld stay in `cc`.
{
  package,
  pkgs,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "llvm";
  uses = [ "cmake" ];
  cmake.root = "llvm";
  cmake.defs =
    import ./defs.nix
    # the nested NATIVE configure (tblgen) would pick the target cc
    // on platform.cross {
      CROSS_TOOLCHAIN_FLAGS_NATIVE = "-DCMAKE_C_COMPILER=cc-build;-DCMAKE_CXX_COMPILER=c++-build";
    };
  dependencies = [
    pkgs.zlib
    pkgs.zstd
  ];
  buildDependencies = [ buildPkgs.cpython ];
  tests.run = false; # LLVM_INCLUDE_TESTS off: hours
  bin = [ "llvm-config" ];
}
