# What `uses = [ "<name>" ]` means at eval time: builder/systems/<name>.nu implements the phases
# and declares the options (its OPTIONS, merged and checked by prepare.nu, read as `options
# <name>`). Here is only what forms derivation inputs: `phases`, the default order (build test
# install unless said otherwise), `tool` (swappable per package as `<name>.tool`) and `tools` (a
# list, or spec -> list) on PATH, `dependencies` added to the package's, `deps` (spec -> the
# fetched tree of locked dependencies, by default from the package's own lock file, a package
# overrides it as `<name>.deps`), `prebuilt` as the package's default for that field, and
# `unsupported`, a reason (or null) why no user of it can build on this platform. Every system
# also takes `<name>.root`, the directory below the source the project lives in. `sh` is for
# tools that spawn a shell by name (ninja, npm run, libtool).
{
  buildPkgs,
  pkgs,
  platform,
  fetch,
  sh,
  lib,
}:
let
  # bin scripts say #!/usr/bin/env node, prebuilt .node addons (rollup, esbuild) link libgcc_s.so.1
  nodeDeps = [
    pkgs.nodejs
    pkgs.libgcc-shim
  ];
  nodeTools = [ buildPkgs.libgcc-shim ]; # the same addons while building (builder/node-common.nu)
in
builtins.mapAttrs
  (
    name: bs:
    let
      extra = if builtins.isFunction (bs.tools or [ ]) then bs.tools else _: bs.tools or [ ];
    in
    {
      module = "systems/${name}.nu";
      phases = map (v: "${name}.${v}") (
        bs.phases or [
          "build"
          "test"
          "install"
        ]
      );
      # script text nix/package.nix would otherwise assemble per package: the setup block and,
      # for any "<name>.<verb>" a package may list, its body and whether it is a test phase
      setup = "note setup ${name}\ndo --env {\nmkdir (${name} workdir)\ncd (${name} workdir)\n${name} setup\n}";
      phase = builtins.listToAttrs (
        map
          (verb: {
            name = "${name}.${verb}";
            value = {
              test = verb == "test";
              body = "note phase ${name}.${verb}\ndo {\ncd (${name} workdir)\n${name} ${verb}\n}";
            };
          })
          [
            "configure"
            "build"
            "test"
            "install"
          ]
      );
      # what the package's `<name>` record starts from at eval time: root, tool, deps
      defaults =
        source:
        {
          root = ".";
        }
        // (if bs ? tool then { inherit (bs) tool; } else { })
        // (if bs ? deps then { deps = bs.deps { inherit source; }; } else { });
      # `tool`: the build system's own program, a package may swap it (`cmake.tool = …`)
      tools = spec: (if bs ? tool then [ spec.${name}.tool ] else [ ]) ++ extra spec;
      dependencies = bs.dependencies or [ ];
      prebuilt = bs.prebuilt or false;
      unsupported = bs.unsupported or null;
      stack = bs.stack or [ ];
    }
  )
  {
    make = {
      phases = [
        "configure"
        "build"
        "test"
        "install"
      ];
      tools = [ sh ];
    };
    autotools = {
      unsupported =
        if platform.libc == "msvc" then
          "configure and libtool do not know the MSVC ABI, config.sub rejects the triple"
        else
          null;
      phases = [
        "configure"
        "build"
        "test"
        "install"
      ];
      # make and bash come with baseTools (or the seed's for bootstrapTools packages)
      tools = [ sh ];
    };
    cmake = {
      phases = [
        "configure"
        "build"
        "test"
        "install"
      ];
      tool = buildPkgs.cmake;
      tools = [
        buildPkgs.ninja
        sh
      ];
    };
    vcxproj = {
      unsupported =
        if platform.libc != "msvc" then "Visual Studio projects describe an MSVC-ABI build" else null;
      phases = [
        "configure"
        "build"
        "install"
      ];
      tools = [ buildPkgs.ninja ];
    };
    meson = {
      phases = [
        "configure"
        "build"
        "test"
        "install"
      ];
      tool = buildPkgs.meson;
      tools = [
        buildPkgs.ninja
        sh
      ];
    };
    python = {
      phases = [
        "build"
        "install"
        "test"
      ]; # tests import the installed module
      # the PEP 517 front end and its deps. Members of the stack itself get only what exists before them
      tool = buildPkgs.cpython;
      # cross: extension modules compile against the target's headers and libpython. Where
      # cpython cannot be built (mingw) neither can its packages
      dependencies = lib.on platform.cross [ pkgs.cpython ];
      stack = with buildPkgs; [
        python-flit-core
        python-packaging
        python-pyproject-hooks
        python-build
        python-installer
      ];
    };
    cargo = {
      # `cargo.tool = buildPkgs.rust-bootstrap` for what must exist before llvm and rust are
      # built (formatelf, git). Cross: std for the target is its own package, <tool>-std
      tool = buildPkgs.rust;
      tools = spec: lib.on platform.cross [ pkgs."${spec.cargo.tool.pname}-std" ];
      deps = fetch.cargoVendor;
    };
    cabal = {
      unsupported = if platform.cross then "ghc-bootstrap only targets the build machine" else null;
      # `cabal.tool = buildPkgs.cabal-bootstrap` for cabal itself
      tool = buildPkgs.cabal;
      tools = [
        buildPkgs.ghc-bootstrap
        buildPkgs.jsem
      ];
      dependencies = [
        pkgs.gmp # ghc-bignum: every linked program wants -lgmp
        pkgs.libffi # and the RTS -lffi
      ];
      # the shared set from locks/hackage.toml
      deps = _: fetch.hackageSet { };
    };
    luarocks = {
      phases = [ "install" ]; # luarocks make builds into --tree
      tool = buildPkgs.luarocks;
      tools = [ sh ];
      # the shared set from locks/luarocks.toml
      deps = _: fetch.luaRocksSet { inherit (buildPkgs) lua; };
    };
    go = {
      tool = buildPkgs.go;
      deps = fetch.goModules;
    };
    pnpm = {
      tool = buildPkgs.pnpm;
      tools = [
        buildPkgs.nodejs
        sh
      ]
      ++ nodeTools;
      deps = fetch.pnpmDeps;
      dependencies = nodeDeps;
    };
    pyapp = {
      # binary wheels carry upstream-linked .so files: finish implants interp/RUNPATH like for any
      # prebuilt package (after split-debug, llvm-objcopy crashes on formatelf's layout)
      prebuilt = true;
      deps = args: fetch.pythonDeps (args // { python = pkgs.cpython; });
      # uv.lock does not lock build backends: every one the set has
      tools =
        with buildPkgs;
        [
          cpython
          python-build
          python-installer
          python-pyproject-hooks
          python-packaging
          python-flit-core
          python-setuptools
          python-setuptools-scm
          python-hatchling
          python-hatch-vcs
          python-cython
          maturin
          rust
        ]
        ++ lib.on platform.cross [ pkgs.rust-std ];
    };
    bundler = {
      tool = buildPkgs.ruby;
      tools = [ sh ];
      deps = fetch.gems;
    };
    deno = {
      tool = buildPkgs.deno;
      deps = fetch.denoDeps;
    };
    bun = {
      tool = buildPkgs.bun;
      tools = [ sh ] ++ nodeTools;
      deps = fetch.bunDeps;
      dependencies = nodeDeps;
    };
    yarn = {
      tool = buildPkgs.yarn;
      tools = [
        buildPkgs.nodejs
        sh
      ]
      ++ nodeTools;
      deps = fetch.yarnDeps;
      dependencies = nodeDeps;
    };
    mix = {
      # no test phase by default: MIX_ENV=test deps are outside the prod lock subset
      phases = [
        "build"
        "install"
      ];
      tool = buildPkgs.elixir;
      tools = [
        buildPkgs.erlang
        buildPkgs.hex
        buildPkgs.rebar3
      ];
      deps = fetch.hexDeps;
      dependencies = [ pkgs.erlang ]; # escripts say #!/usr/bin/env escript, releases exec erl
    };
    rebar3 = {
      # no test phase by default: eunit/ct deps live in the test profile, outside rebar.lock
      phases = [
        "build"
        "install"
      ];
      tools = [
        buildPkgs.rebar3
        buildPkgs.erlang
      ];
      deps = fetch.hexDeps;
      dependencies = [ pkgs.erlang ];
    };
    npm = {
      tool = buildPkgs.nodejs;
      tools = [ sh ] ++ nodeTools;
      deps = fetch.npmDeps;
      dependencies = nodeDeps;
    };
  }
