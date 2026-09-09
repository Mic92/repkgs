# libLLVM of the major rustc bundles (src/llvm-project in the rustc tarball), one behind ours:
# rustc's feature tables track that major and reject or invent names on a newer one (amx-tf32).
# Same shape as pkgs/ll/llvm.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "llvm22";
  uses = [ "cmake" ];
  cmake.root = "llvm";
  cmake.defs = import ../llvm/defs.nix;
  dependencies = [
    pkgs.zlib
    pkgs.zstd
  ];
  buildDependencies = [ buildPkgs.cpython ];
  tests.run = false; # hours, as llvm
  bin = [ "llvm-config" ];
}
