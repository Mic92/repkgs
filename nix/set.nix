# The package set for one platform and what it is made from: { pkgs, bootstrap, buildSystems }.
# default.nix is `pkgs` alone; nix/checks.nix reads the rest.
{
  system ? builtins.currentSystem,
  platform ? system,
  seed ? null,
  overrides ? { },
  packages ? { },
  features ? { },
}:
let
  ov = import ./overrides.nix;
  overrideTree = ov.merge overrides;
  feat = import ./features.nix;
  bootstrap = import ../bootstrap { inherit seed system; };

  platforms = import ./platforms.nix;
  target = platforms.byName.${platform} or (throw "no platform ${platform}");
  stage = bootstrap.toolchain.${platform} (
    lib.on (target.libc == "msvc") {
      sdk = fetch.windowsSdk {
        manifest = (readSources ../pkgs/wi/windows-sdk/sources.toml).fetch "default";
        arch = target.cpu;
      };
    }
  );
  inherit (target) os;
  plat = stage.platform // rec {
    inherit system;
    cross = platform != system;
    buildRustTriple = (platforms.forSystem system "glibc").rustTriple;
    # its address cap is $QEMU_RESERVED_VA (builder/prepare.nu), build systems want one word here
    emulator =
      if cross && os == "linux" then
        [ "${buildPkgs.qemu}/bin/qemu-${stage.platform.names.qemu}" ]
      else if cross && os == "windows" && target.cpu == "x86_64" then
        [ "${buildPkgs.wine}/bin/wine" ]
      else
        [ ];
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
  lib = import ./lib.nix;
  inherit (lib) on;
  buildSystems = import ./build-systems.nix {
    inherit buildPkgs fetch lib;
    platform = plat;
    pkgs = self;
    sh = bootstrap.seed;
  };
  # On PATH after the toolchain and the build systems' tools. GNU userland precedes the seed because
  # build scripts in the wild need more than toybox. llvm brings the object tools, the seed bsdtar,
  # nu, sh. `bootstrap` is what the base userland itself is built with (`bootstrapTools = true`).
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
      ++ [
        bootstrap.llvm
        bootstrap.seed
      ];
    bootstrap = [
      bootstrap.llvm
      bootstrap.seed
    ];
  };

  package = import ./package.nix {
    platform = plat;
    nu = bootstrap.seed;
    inherit lib;
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
    # [pin] sys names resolve here
    pkgs = self;
  };

  fetch = import ./fetch.nix {
    inherit (bootstrap.stage0) jig;
    sevenzip = buildPkgs."7zip";
    nu = bootstrap.seed;
    inherit system;
    inherit (plat) cpu;
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
    inherit lib on;
    # cpython's package.nix adds .env/.project with this (nix/python.nix)
    pythonProject =
      package: python:
      import ./python.nix {
        inherit
          package
          fetch
          python
          buildPkgs
          ;
        pkgs = self;
      };
  };
  readSources = import ./sources.nix {
    unpacker = bootstrap.seed;
    inherit system;
  };
  callPackage =
    dir: name:
    let
      st = dir + "/sources.toml";
      sources = if builtins.pathExists st then readSources st else null;
    in
    callWith (import (dir + "/package.nix")) dir name sources null;
  # one package.nix evaluated under `name`: `fn` its function, `edit0` what `variant` adds on
  # top of the spec (identity for the package itself). `variant pkgs.llvm { … }` re-enters here
  # with llvm's function, so the base body sees this name's sources and features
  callWith =
    fn: dir: name: sources: edit0:
    let
      formals = builtins.functionArgs fn;
      edit = if edit0 == null then (a: a) else edit0;
      local = overrideTree.${name}.features or { };
      # default <- set-wide <- overrides.<name>.features, for a package.nix that takes `features`.
      # Its declaration is read by one more call whose `package` just returns it: lazy (no spec
      # is built), and the real call's dependencies may then depend on feature values. One that
      # declares features without reading them only pays when overridden
      resolved =
        if formals ? features || local != { } then
          feat.resolve name
            (fn (
              builtins.intersectAttrs formals (
                scope
                // {
                  inherit sources;
                  features = { };
                  package = a: { decl = (edit a).features or { }; };
                  variant = base: _tree: { inherit (base) decl; };
                }
              )
            )).decl
            features
            local
        else
          { };
      result = fn (
        builtins.intersectAttrs formals (
          scope
          // {
            inherit sources;
            features = resolved;
            package =
              if edit0 == null then
                package sources dir resolved fn
              else
                args: package sources dir resolved fn (edit0 args);
            # another package's spec under this name, edited with override verbs: this function
            # again with the base's package.nix. Own sources.toml when the directory has one
            # (llvm22: another pin), else the base's (rust-std: same tarball). A list of trees merges
            variant =
              base: tree:
              callWith base.fn base.dir name (if sources == null then base.sources else sources) (
                args: ov.applyOne self name (ov.merge tree) (edit args // { inherit name; })
              );
          }
        )
      );
    in
    result;

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
  # attrNames alone would not force the platform: `list --for typo` showed this machine's set
  pkgs = builtins.seq stage (
    if unknownOverrides != [ ] then
      throw "overrides: no packages named ${toString unknownOverrides}"
    else
      self
  );
  inherit bootstrap buildSystems toolchain;
  bundle = import ./bundle.nix {
    nu = bootstrap.seed;
    tools = [ buildPkgs.formatelf ] ++ baseTools.bootstrap;
    tree = ../builder;
  };
}
