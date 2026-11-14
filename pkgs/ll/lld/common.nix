# lld's libraries and ld.lld against llvm<v>. lld<v>/package.nix is `import this "<v>"`
v:
{
  variant,
  pkgs,
  buildPkgs,
}:
let
  llvm = pkgs.${"llvm" + v};
  buildLlvm = buildPkgs.${"llvm" + v};
in
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
    bin.set = [
      "ld.lld"
      "lld"
    ];
    # by name, not -flavor: on windows lld takes its flavor from the file it runs as, which
    # builder/pe.nu keeps
    tests.version.set = "ld.lld --version";
  }
