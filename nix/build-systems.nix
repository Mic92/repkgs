# What `uses = [ "<name>" ]` means: builder/<name>.nu implements the verbs, `verbs` is the default
# step order (build test install unless said otherwise), `tools` go on PATH, and `knobs` are what a
# package may set under `<name>.*` (anything else is an eval error). `lock = knob: fetcher` gives
# that knob the package's own lock file, fetched from its source, as default. `sh` is for tools
# that spawn a shell by name (ninja, npm run, libtool).
{
  buildPkgs,
  fetch,
  sh,
}:
builtins.mapAttrs
  (name: bs: {
    module = "${name}.nu";
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
        "sourceDir"
        "generator"
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
        "sourceDir"
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
      lock.vendor = fetch.cargoVendor;
      knobs = [
        "features"
        "noDefaultFeatures"
        "root"
        "vendor"
        "toolchain"
      ];
    };
    cabal = {
      tools = [
        buildPkgs.ghc-bootstrap
        buildPkgs.cabal-bootstrap
      ];
      # the shared version set (locks/hackage.toml) every cabal package solves against
      defaults.set = fetch.hackageSet { };
      knobs = [
        "set"
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
      defaults.set = fetch.luaRocksSet { inherit (buildPkgs) lua; };
      knobs = [
        "set"
        "rockspec"
        "root"
        "flags"
      ];
    };
    go = {
      tools = [ buildPkgs.go ];
      lock.modules = fetch.goModules;
      knobs = [
        "tags"
        "ldflags"
        "packages"
        "testPackages"
        "root"
        "modules"
        "cgo"
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
        "test"
        "flags"
      ];
    };
    pyapp = {
      tools = with buildPkgs; [
        cpython
        python-build
        python-installer
        python-pyproject-hooks
        python-packaging
        python-flit-core
        python-setuptools
        python-hatchling
        formatelf
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
      lock.gems = fetch.gems;
      knobs = [
        "root"
        "gems"
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
        "test"
        "check"
        "flags"
      ];
    };
    bun = {
      tools = [
        buildPkgs.bun
        sh
      ];
      knobs = [
        "root"
        "script"
        "deps"
        "test"
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
        "test"
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
        "test"
        "flags"
      ];
    };
  }
