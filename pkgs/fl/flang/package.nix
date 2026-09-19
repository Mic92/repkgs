# LLVM's Fortran compiler, standalone against llvm, clang and mlir of the same pin
{
  variant,
  pkgs,
  buildPkgs,
}:
import ../../ll/llvm/subproject.nix
  {
    inherit variant pkgs buildPkgs;
    inherit (pkgs) llvm;
    buildLlvm = buildPkgs.llvm;
  }
  "flang"
  {
    cmake.defs.merge = {
      CLANG_DIR = "${pkgs.clang}/lib/cmake/clang";
      MLIR_DIR = "${pkgs.mlir}/lib/cmake/mlir";
      MLIR_TABLEGEN_EXE = "${buildPkgs.mlir}/bin/mlir-tblgen";
      FLANG_INCLUDE_TESTS = false;
      FLANG_INCLUDE_DOCS = false;
    };
    dependencies.append = [
      pkgs.clang
      pkgs.mlir
    ];
    platforms.set.cross = false;
    bin.set = [ "flang" ];
    tests.version.set = true;
  }
