# MLIR libraries and mlir-tblgen against llvm, for flang
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
  "mlir"
  {
    cmake.defs.merge = {
      MLIR_INCLUDE_TESTS = false;
      MLIR_INCLUDE_INTEGRATION_TESTS = false;
      MLIR_INCLUDE_DOCS = false;
      MLIR_ENABLE_BINDINGS_PYTHON = false;
      MLIR_INSTALL_AGGREGATE_OBJECTS = false;
      # tools linked against libMLIR lose their tablegen header dependencies (23.1)
      MLIR_LINK_MLIR_DYLIB = false;
    };
    platforms.set.cross = false;
    # not installed upstream, flang's configure wants it
    phases.after.set."cmake.install" = [
      {
        name = "mlir-tblgen";
        run = "cp bin/mlir-tblgen $\"($c.out)/bin/\"";
      }
    ];
    bin.set = [ "mlir-tblgen" ];
  }
