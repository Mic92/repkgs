# What `uses = [ "<name>" ]` means: builder/systems/<name>.nu implements the verbs, `verbs` is the default
# step order (build test install unless said otherwise), `tools` go on PATH, `libs` into
# `dependencies`, `prebuilt` is the package's default for that field, and `knobs` are what a
# package may set under `<name>.*` (anything else is an eval error). Three knobs mean the same
# everywhere: `root` (the project's directory below the source), `deps` (the fetched tree of
# locked dependencies) and `flags` (extra words on the tool's command line). `lock.deps = fetcher` defaults it to the package's own lock file. `sh` is for tools
# that spawn a shell by name (ninja, npm run, libtool).
{
  buildPkgs,
  pkgs,
  fetch,
  sh,
}:
builtins.mapAttrs
  (name: bs: {
    module = "systems/${name}.nu";
    steps = map (v: "${name}.${v}") (
      bs.verbs or [
        "build"
        "test"
        "install"
      ]
    );
    defaults =
      args:
      builtins.mapAttrs (_: f: f { inherit (args) source; }) (bs.lock or { }) // (bs.defaults or { });
    inherit (bs) knobs;
    tools = if builtins.isFunction bs.tools then bs.tools else _: bs.tools;
    libs = bs.libs or [ ];
    prebuilt = bs.prebuilt or false;
    stack = bs.stack or [ ];
  })
  {
    autotools = {
      verbs = [
        "configure"
        "build"
        "test"
        "install"
      ];
      # make and bash come with baseTools (or the seed's for bootstrapTools packages)
      tools = [ sh ];
      knobs = [
        "flags"
        "makeFlags"
        "installFlags"
        "configureScript"
        "outOfTree"
        "testTarget"
        "buildTarget"
      ];
    };
    cmake = {
      verbs = [
        "configure"
        "build"
        "test"
        "install"
      ];
      tools = [
        buildPkgs.cmake
        buildPkgs.ninja
        sh
      ];
      knobs = [
        "defs"
        "root"
        "generator"
        "flags"
      ];
    };
    meson = {
      verbs = [
        "configure"
        "build"
        "test"
        "install"
      ];
      tools = [
        buildPkgs.meson
        buildPkgs.ninja
        sh
      ];
      knobs = [
        "options"
        "flags"
        "root"
      ];
    };
    python = {
      verbs = [
        "build"
        "install"
        "test"
      ]; # tests import the installed module
      # the PEP 517 front end and its deps. Members of the stack itself get only what exists before them
      tools = [ buildPkgs.cpython ];
      stack = with buildPkgs; [
        python-flit-core
        python-packaging
        python-pyproject-hooks
        python-build
        python-installer
      ];
      knobs = [
        "backend"
        "module"
        "root"
        "pytest"
      ];
    };
    cargo = {
      # `cargo.toolchain = buildPkgs.rust-bootstrap` for what must exist before llvm and rust are
      # built: formatelf, which every `prebuilt = true` package needs
      tools = args: [ (args.cargo.toolchain or buildPkgs.rust) ];
      lock.deps = fetch.cargoVendor;
      knobs = [
        "features"
        "noDefaultFeatures"
        "flags"
        "root"
        "deps"
        "toolchain"
      ];
    };
    cabal = {
      tools = [
        buildPkgs.ghc-bootstrap
        buildPkgs.cabal-bootstrap
      ];
      # GHC's threaded RTS ends threads with pthread_exit, for which glibc dlopens libgcc_s.so.1:
      # in the RUNPATH of what is installed, on LD_LIBRARY_PATH (its env export) while building.
      libs = [
        pkgs.libgcc-shim
        pkgs.gmp # ghc-bignum: every linked program wants -lgmp
        pkgs.libffi # and the RTS -lffi
      ];
      # the shared version set (locks/hackage.toml) every cabal package solves against
      defaults.deps = fetch.hackageSet { };
      knobs = [
        "deps"
        "flags"
        "exes"
        "project"
        "root"
      ];
    };
    luarocks = {
      verbs = [ "build" ];
      tools = [
        buildPkgs.luarocks
        sh
      ];
      # the shared rock versions (locks/luarocks.toml)
      defaults.deps = fetch.luaRocksSet { inherit (buildPkgs) lua; };
      knobs = [
        "deps"
        "rockspec"
        "root"
        "flags"
      ];
    };
    go = {
      tools = [ buildPkgs.go ];
      lock.deps = fetch.goModules;
      knobs = [
        "tags"
        "ldflags"
        "packages"
        "testPackages"
        "root"
        "deps"
        "cgo"
        "flags"
      ];
    };
    pnpm = {
      tools = [
        buildPkgs.pnpm
        buildPkgs.nodejs
        sh
      ];
      lock.deps = fetch.pnpmDeps;
      knobs = [
        "root"
        "script"
        "deps"
        "flags"
      ];
    };
    pyapp = {
      # binary wheels carry upstream-linked .so files: finish implants interp/RUNPATH like for any
      # prebuilt package (after split-debug, llvm-objcopy crashes on formatelf's layout)
      prebuilt = true;
      lock.deps = args: fetch.pythonDeps (args // { python = pkgs.cpython; });
      tools = with buildPkgs; [
        cpython
        python-build
        python-installer
        python-pyproject-hooks
        python-packaging
        python-flit-core
        python-setuptools
        python-hatchling
      ];
      knobs = [
        "root"
        "deps"
        "check"
      ];
    };
    bundler = {
      tools = [
        buildPkgs.ruby
        sh
      ];
      lock.deps = fetch.gems;
      knobs = [
        "root"
        "deps"
        "without"
        "test"
        "flags"
      ];
    };
    deno = {
      tools = [ buildPkgs.deno ];
      lock.deps = fetch.denoDeps;
      knobs = [
        "root"
        "deps"
        "entry"
        "permissions"
        "check"
        "flags"
      ];
    };
    bun = {
      tools = [
        buildPkgs.bun
        sh
      ];
      lock.deps = fetch.bunDeps;
      knobs = [
        "root"
        "script"
        "deps"
        "flags"
        "compile"
      ];
    };
    yarn = {
      tools = [
        buildPkgs.yarn
        buildPkgs.nodejs
        sh
      ];
      lock.deps = fetch.yarnDeps;
      knobs = [
        "root"
        "script"
        "deps"
        "flags"
      ];
    };
    npm = {
      tools = [
        buildPkgs.nodejs
        sh
      ];
      lock.deps = fetch.npmDeps;
      knobs = [
        "root"
        "script"
        "deps"
        "flags"
      ];
    };
  }
