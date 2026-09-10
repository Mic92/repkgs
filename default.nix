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
let
  platforms = import ./nix/platforms.nix;
  ov = import ./nix/overrides.nix;
  overrideTree = ov.merge overrides;
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
        inherit
          seed
          system
          overrides
          packages
          ;
      }
    else
      self;

  # build systems that spawn `sh` by name get the seed's dash
  buildSystems = import ./nix/build-systems.nix {
    inherit buildPkgs fetch;
    pkgs = self;
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
    # `prebuilt = true` patches upstream ELFs with it (builder/implant.nu)
    relocTools = [ buildPkgs.formatelf ];
    inherit
      toolchain
      launch
      buildSystems
      baseTools
      ;
    # identity when there are none, so the common case allocates nothing per package
    edit = if overrideTree == { } then null else ov.apply self overrideTree;
  };

  fetch = import ./nix/fetch.nix {
    inherit (bootstrap.stage0) jig;
    nu = bootstrap.seed;
    inherit system;
    inherit (plat) cpu;
    # what the lock-file producers may hand to -sys crates, cgo modules, gems…: every `pkg:` that
    # builder/sys-libs.nu names and the set has
    sysLibs =
      let
        words = builtins.filter builtins.isList (
          builtins.split "pkg: ([a-z0-9-]+)" (builtins.readFile ./builder/sys-libs.nu)
        );
        names = map builtins.head words;
      in
      builtins.listToAttrs (
        map (n: {
          name = n;
          value = self.${n};
        }) (builtins.filter (n: self ? ${n}) names)
      );
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
    dir: name:
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
          # another package's spec under this name and sources.toml, edited with override verbs
          variant = base: tree: package sources (ov.applyOne self name tree (base.args // { inherit name; }));
        }
      )
    );

  # pkgs/<first two letters>/<name>/package.nix, attribute name == directory name
  unknownOverrides = ov.unknown (self // aliases) overrideTree;
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
            value = callPackage (dir + "/${n}") n;
          })
          (
            builtins.filter (n: builtins.pathExists (dir + "/${n}/package.nix")) (
              builtins.attrNames (builtins.readDir dir)
            )
          )
      ) (builtins.attrNames (removeAttrs (builtins.readDir ./pkgs) [ "aliases.toml" ]))
    )
    // builtins.mapAttrs (n: dir: callPackage dir n) packages
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
if unknownOverrides != [ ] then
  throw "overrides: no packages named ${toString unknownOverrides}"
else
  self
  // {
    inherit bootstrap toolchain;
    platform = plat;
    # for tools/options: name -> { doc, type, default } per build system, `deps` defaults (derivations) elided
    options = builtins.mapAttrs (
      _: bs:
      builtins.mapAttrs (
        _: o:
        o
        // {
          default = if builtins.elem "set" o.type && builtins.elem "string" o.type then null else o.default;
        }
      ) bs.options
    ) buildSystems;
  }
