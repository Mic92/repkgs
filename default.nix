# The package set for one platform.
#   nix-build -A zlib                                  build machine's platform
#   nix-build -A zlib --argstr platform riscv64-linux  cross (tools still run on the build machine)
#
# Every directory pkgs/<name>/ with a package.nix becomes attribute <name>. A package.nix is
#   { package, pkgs, ... }: package { name = "<name>"; ... dependencies = [ pkgs.zlib ]; }
# and may take any of: package pkgs buildPkgs platform fetch sources toolchain.
{
  system ? builtins.currentSystem,
  platform ? system,
  seed ? null,
}:
let
  platforms = import ./nix/platforms.nix;
  bootstrap = import ./bootstrap { inherit seed system; };

  cpu = builtins.head (builtins.split "-" platform);
  plat = platforms.glibc.${cpu} // rec {
    inherit system;
    cross = platform != system;
    emulator =
      if cross then [ "${buildPkgs.qemu}/bin/qemu-${platforms.glibc.${cpu}.names.qemu}" ] else [ ];
  };
  toolchain = bootstrap.stage1.${cpu}.cc;
  launch = bootstrap.stage1.${cpu}.launch;
  buildPkgs =
    if plat.cross then
      import ./. {
        platform = system;
        inherit seed system;
      }
    else
      self;

  # build systems that spawn `sh` by name get the seed's dash
  buildSystems = import ./nix/build-systems.nix {
    inherit buildPkgs;
    sh = bootstrap.seed;
  };
  # On PATH after the toolchain and the build systems' tools. GNU userland precedes the seed because
  # build scripts in the wild need more than toybox. The seed contributes llvm-*, bsdtar, nu, sh.
  # `bootstrap` is what the base userland packages themselves are built with (`bootstrapTools =
  # true` in package.nix): only the seed's static tools, so the set has no cycle and no nixpkgs.
  baseTools = {
    full =
      (with buildPkgs; [
        coreutils
        sed
        grep
        gawk
        diffutils
        findutils
        patch
        gnumake
        bash
        pkgconf
      ])
      ++ [ bootstrap.seed ];
    bootstrap = [ bootstrap.seed ];
  };

  package = import ./nix/package.nix {
    platform = plat;
    nu = bootstrap.seed;
    inherit
      toolchain
      launch
      buildSystems
      baseTools
      ;
  };

  fetch = import ./nix/fetch.nix {
    inherit (bootstrap.stage0) jig;
    nu = bootstrap.seed;
    inherit system;
  };

  scope = {
    inherit
      package
      fetch
      toolchain
      buildPkgs
      ;
    platform = plat;
    pkgs = self;
  };
  readSources = import ./nix/sources.nix {
    unpacker = bootstrap.seed;
    inherit system;
  };
  callPackage =
    dir:
    let
      fn = import (dir + "/package.nix");
      st = dir + "/sources.toml";
      sources = if builtins.pathExists st then readSources st else null;
    in
    fn (
      builtins.intersectAttrs (builtins.functionArgs fn) (
        scope
        // {
          inherit sources;
          package = package sources;
        }
      )
    );

  # pkgs/<first two letters>/<name>/package.nix, attribute name == directory name
  self =
    builtins.listToAttrs (
      builtins.concatMap (
        shard:
        let
          dir = ./pkgs + "/${shard}";
        in
        map
          (n: {
            name = n;
            value = callPackage (dir + "/${n}");
          })
          (
            builtins.filter (n: builtins.pathExists (dir + "/${n}/package.nix")) (
              builtins.attrNames (builtins.readDir dir)
            )
          )
      ) (builtins.attrNames (removeAttrs (builtins.readDir ./pkgs) [ "aliases.toml" ]))
    )
    // aliases;
  # unversioned names for the default line of multi-version packages (pkgs/aliases.toml)
  aliases = builtins.mapAttrs (
    alias: target:
    if builtins.pathExists (./pkgs + "/${builtins.substring 0 2 alias}/${alias}/package.nix") then
      throw "alias ${alias} shadows a package directory"
    else
      self.${target}
  ) (builtins.fromTOML (builtins.readFile ./pkgs/aliases.toml));
in
self
// {
  inherit bootstrap toolchain;
  platform = plat;
}
