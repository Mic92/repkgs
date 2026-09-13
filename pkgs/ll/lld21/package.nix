{
  variant,
  pkgs,
  buildPkgs,
}:
import ../lld/package.nix {
  inherit variant pkgs buildPkgs;
  llvm = pkgs.llvm21;
  buildLlvm = buildPkgs.llvm21;
}
