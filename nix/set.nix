# The package set for one platform and what it is made from: { pkgs, bootstrap, buildSystems }.
# default.nix is `pkgs` alone; nix/options.nix and nix/ci.nix read the rest.
{
  system ? builtins.currentSystem,
  platform ? system,
  seed ? null,
  overrides ? { },
  packages ? { },
}:
let
  ov = import ./overrides.nix;
  overrideTree = ov.merge overrides;
  bootstrap = import ../bootstrap { inherit seed system; };

  cpu = builtins.head (builtins.split "-" platform);
  windows = builtins.match ".*-windows" platform != null;
  # <cpu>-windows: the msvc toolchain over the SDK the build machine's set fetches
  stage =
    if windows then
      bootstrap.msvc cpu (
        fetch.windowsSdk {
          manifest = (readSources ../pkgs/wi/windows-sdk/sources.toml).fetch "default";
          arch = cpu;
        }
      )
    else
      bootstrap.stage1.${cpu};
  plat = stage.platform // rec {
    inherit system;
    cross = platform != system;
    emulator =
      if cross && !windows then [ "${buildPkgs.qemu}/bin/qemu-${stage.platform.names.qemu}" ] else [ ];
  };
  toolchain = stage.cc;
  launch = stage.launch or null;
  dlaudit = stage.dlaudit or null;
  buildPkgs =
    if plat.cross then
      (import ./set.nix {
        platform = system;
        inherit
          seed
          system
          overrides
          packages
          ;
      }).pkgs
    else
      self;

  # build systems that spawn `sh` by name get the seed's dash
  buildSystems = import ./build-systems.nix {
    inherit buildPkgs fetch;
    platform = plat;
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

  package = import ./package.nix {
    platform = plat;
    nu = bootstrap.seed;
    # `prebuilt = true` patches upstream ELFs with it (builder/implant.nu)
    relocTools = [ buildPkgs.formatelf ];
    inherit
      toolchain
      launch
      dlaudit
      buildSystems
      baseTools
      ;
    # identity when there are none, so the common case allocates nothing per package
    edit = if overrideTree == { } then null else ov.apply self overrideTree;
  };

  fetch = import ./fetch.nix {
    inherit (bootstrap.stage0) jig;
    sevenzip = buildPkgs."7zip";
    nu = bootstrap.seed;
    inherit system;
    inherit (plat) cpu;
    # what the lock-file producers may hand to -sys crates, cgo modules, gems…: every `pkg:` that
    # builder/sys-libs.nu names and the set has
    sysLibs =
      let
        words = builtins.filter builtins.isList (
          builtins.split "pkg: ([a-z0-9-]+)" (builtins.readFile ../builder/sys-libs.nu)
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
  readSources = import ./sources.nix {
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
          # another package's spec under this name, edited with override verbs. Own sources.toml
          # when the directory has one (llvm22: another pin), else the base's (rust-std: same tarball)
          variant =
            base: tree:
            package (if sources == null then base.sources else sources) (
              ov.applyOne self name tree (base.args // { inherit name; })
            );
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
          dir = ../pkgs + "/${shard}";
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
      ) (builtins.attrNames (removeAttrs (builtins.readDir ../pkgs) [ "aliases.toml" ]))
    )
    // builtins.mapAttrs (n: dir: callPackage dir n) packages
    // aliases;
  # unversioned names for the default line of multi-version packages (pkgs/aliases.toml)
  aliases = builtins.mapAttrs (
    alias: target:
    if builtins.pathExists (../pkgs + "/${builtins.substring 0 2 alias}/${alias}/package.nix") then
      throw "alias ${alias} shadows a package directory"
    else
      self.${target}
  ) (builtins.fromTOML (builtins.readFile ../pkgs/aliases.toml));
in
{
  pkgs =
    if unknownOverrides != [ ] then
      throw "overrides: no packages named ${toString unknownOverrides}"
    else
      self;
  inherit bootstrap buildSystems toolchain;
}
