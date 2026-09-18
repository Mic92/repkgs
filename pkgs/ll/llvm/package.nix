# LLVM as a library: libLLVM.so, headers, llvm-config and the object tools, from the same pin the
# toolchain is built from. For rustc (and later zig) to link against. clang and lld stay in `cc`.
{
  package,
  pkgs,
  buildPkgs,
  platform,
  on,
  lib,
}:
let
  inherit (lib) join;
in
package {
  name = "llvm";
  uses = [ "cmake" ];
  cmake.root = "llvm";
  patches = [
    ./upstream-x86-vastart-stack-probe.patch
    ./jig-absent-log.patch
  ];
  cmake.defs =
    import ./defs.nix
    # the nested NATIVE configure (tblgen, host/llvm-config): build cc, static so no build-machine
    # store path lands in $out, and dylib + triple so its llvm-config answers like the target's
    // on platform.cross {
      CROSS_TOOLCHAIN_FLAGS_NATIVE = join ";" [
        "-DCMAKE_C_COMPILER=cc-build"
        "-DCMAKE_CXX_COMPILER=c++-build"
        "-DCMAKE_EXE_LINKER_FLAGS=-static"
        "-DLLVM_BUILD_LLVM_DYLIB=ON"
        "-DLLVM_LINK_LLVM_DYLIB=ON"
        "-DLLVM_HOST_TRIPLE=${platform.clangTarget}"
      ];
    };
  # configure-time tools (cmake, meson, x.py) run llvm-config on the build machine. The NATIVE
  # sub-build makes one from this configure's cache that reports paths relative to itself. In
  # its own directory: bin/ entries get a target launcher, and a find_program pointed here
  # must not see the target llvm-config next to it
  phases.after."cmake.install" = on platform.cross [
    {
      name = "llvm-config-host";
      run = ''
        x cmake --build NATIVE --target llvm-config
        mkdir $"($c.out)/host"
        cp NATIVE/bin/llvm-config $"($c.out)/host/llvm-config"
      '';
    }
  ];
  dependencies = [
    pkgs.zlib
    pkgs.zstd
  ];
  buildDependencies = [ buildPkgs.cpython ];
  tests.run = false; # LLVM_INCLUDE_TESTS off: hours
  bin = [ "llvm-config" ];
}
