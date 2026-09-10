# The package set for one platform.
#   nix-build -A zlib                                  build machine's platform
#   nix-build -A zlib --argstr platform riscv64-linux  cross (tools still run on the build machine)
#
# Every directory pkgs/<name>/ with a package.nix becomes attribute <name>. A package.nix is
#   { package, pkgs, ... }: package { name = "<name>"; ... dependencies = [ pkgs.zlib ]; }
# and may take any of: package variant pkgs buildPkgs platform fetch sources toolchain.
{
  system ? builtins.currentSystem,
  platform ? system,
  seed ? null,
  # one tree or a list of them: { zlib.autotools.flags.append = [ … ]; } (nix/overrides.nix)
  overrides ? { },
  # out-of-tree packages: name -> directory with package.nix (+ sources.toml), called like
  # in-tree ones. A name that exists in the tree is replaced
  packages ? { },
}:
(import ./nix/set.nix {
  inherit
    system
    platform
    seed
    overrides
    packages
    ;
}).pkgs
