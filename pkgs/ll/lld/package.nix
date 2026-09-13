# lld's libraries and ld.lld against llvm<N>
{
  variant,
  pkgs,
  buildPkgs,
  llvm ? pkgs.llvm,
  buildLlvm ? buildPkgs.llvm,
}:
import ../llvm/subproject.nix
  {
    inherit
      variant
      pkgs
      buildPkgs
      llvm
      buildLlvm
      ;
  }
  "lld"
  {
    bin.set = [ "ld.lld" ];
    tests.version.set = true;
  }
