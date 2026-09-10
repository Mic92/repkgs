# What `uses = [ "<name>" ]` means: builder/systems/<name>.nu implements the verbs, `verbs` is the default
# step order (build test install unless said otherwise), `tools` go on PATH, `dependencies` add to
# the package's, `prebuilt` is the package's default for that field, and `options` are what a
# package may set under `<name>.*`: `{ type; doc; }` each, `type` the `builtins.typeOf` names
# allowed, checked at eval time along with the name. Every system has `root`; `deps` (the
# fetched tree of locked dependencies, `lock.deps = fetcher` defaults it to the package's own lock
# file) and `flags` (extra words on the tool's command line) mean the same wherever they exist.
# Defaults live with the verbs in the .nu module. `tools/options` renders this as a table. `sh` is
# for tools that spawn a shell by name (ninja, npm run, libtool).
{
  buildPkgs,
  pkgs,
  fetch,
  sh,
}:
let
  opt = type: doc: {
    type = if builtins.isList type then type else [ type ];
    inherit doc;
  };
  str = opt "string";
  strs = opt "list";
  bool = opt "bool";
  attrs = opt "set";
  # a derivation, or the placeholder string a dynamic derivation's output is at eval time
  drv = opt [
    "set"
    "string"
    "null"
  ];
  flags = tool: strs "extra arguments for ${tool}";
  deps =
    fetcher:
    drv "the locked dependencies, fetched (${fetcher}). Defaults to the package's own lock file";
  script = str "package.json script `build` runs (default \"build\", null: none)" // {
    type = [
      "string"
      "null"
    ];
  };
in
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
    options = {
      root = opt "string" "directory below the source the project lives in (monorepos, build/cmake)";
    }
    // bs.options;
    tools = if builtins.isFunction bs.tools then bs.tools else _: bs.tools;
    dependencies = bs.dependencies or [ ];
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
      options = {
        flags = flags "configure";
        makeFlags = strs "arguments for every make invocation (build, test, install)";
        installFlags = strs "arguments for `make install` only";
        configureScript = str "configure script relative to the project (default \"configure\")";
        outOfTree = bool "configure from a separate build directory (default true)";
        buildTarget = strs "make goals for build (default: the makefile's default goal)";
        testTarget = strs "make goals for test (default [\"check\"])";
      };
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
      options = {
        defs = attrs "-D cache entries. true/false render ON/OFF, packages their store path";
        generator = str "cmake -G (default \"Ninja\")";
        flags = flags "cmake at configure time";
      };
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
      options = {
        defs = attrs "-D options, merged over prefix/libdir/buildtype defaults";
        flags = flags "meson setup";
      };
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
      options = {
        backend = str "PEP 517 backend when pyproject.toml names none: setuptools (default), flit_core, maturin";
        module = str "module the import test loads (default: the package name with - as _)" // {
          type = [
            "string"
            "null"
          ];
        };
        pytest = bool "also run pytest on tests/ (default false)";
      };
    };
    cargo = {
      # `cargo.toolchain = buildPkgs.rust-bootstrap` for what must exist before llvm and rust are
      # built: formatelf, which every `prebuilt = true` package needs
      tools = args: [ (args.cargo.toolchain or buildPkgs.rust) ];
      lock.deps = fetch.cargoVendor;
      options = {
        features = strs "--features";
        noDefaultFeatures = bool "--no-default-features (default false)";
        flags = flags "cargo build and cargo test";
        deps = deps "fetch.cargoVendor";
        toolchain = drv "the rust to build with (default buildPkgs.rust, rust-bootstrap before that exists)";
      };
    };
    cabal = {
      tools = [
        buildPkgs.ghc-bootstrap
        buildPkgs.cabal-bootstrap
        buildPkgs.jsem
      ];
      # GHC's threaded RTS ends threads with pthread_exit, for which glibc dlopens libgcc_s.so.1:
      # in the RUNPATH of what is installed, on LD_LIBRARY_PATH (its env export) while building.
      dependencies = [
        pkgs.libgcc-shim
        pkgs.gmp # ghc-bignum: every linked program wants -lgmp
        pkgs.libffi # and the RTS -lffi
      ];
      # the shared version set (locks/hackage.toml) every cabal package solves against
      defaults.deps = fetch.hackageSet { };
      options = {
        deps =
          drv "hackage repository to solve against (default: the shared set from locks/hackage.toml)"
          // {
            type = [
              "set"
              "string"
            ];
          };
        flags = flags "every cabal subcommand (--flags=…, --allow-newer)";
        exes = strs "exe components to build and install";
        project = str "extra cabal.project text (allow-newer:, constraints:)";
      };
    };
    luarocks = {
      verbs = [ "build" ];
      tools = [
        buildPkgs.luarocks
        sh
      ];
      # the shared rock versions (locks/luarocks.toml)
      defaults.deps = fetch.luaRocksSet { inherit (buildPkgs) lua; };
      options = {
        deps = drv "rock server directory (default: the shared set from locks/luarocks.toml)" // {
          type = [
            "set"
            "string"
          ];
        };
        rockspec = str "rockspec file when the source has several (default: luarocks picks)" // {
          type = [
            "string"
            "null"
          ];
        };
        flags = flags "luarocks make";
      };
    };
    go = {
      tools = [ buildPkgs.go ];
      lock.deps = fetch.goModules;
      options = {
        tags = strs "-tags";
        ldflags = strs "-ldflags words (-X main.version=…)";
        packages = strs "packages to build (default [\"./...\"])";
        testPackages = strs "packages to test (default: `packages`)";
        deps = deps "fetch.goModules" // {
          doc = "GOPROXY tree (fetch.goModules, default from go.sum), or null to build from the source's vendor/";
        };
        cgo = bool "CGO_ENABLED and external linking (default true)";
        flags = flags "go build and go test";
      };
    };
    pnpm = {
      tools = [
        buildPkgs.pnpm
        buildPkgs.nodejs
        sh
      ];
      lock.deps = fetch.pnpmDeps;
      dependencies = [ pkgs.nodejs ]; # bin scripts say #!/usr/bin/env node
      options = {
        inherit script;
        deps = deps "fetch.pnpmDeps";
        flags = flags "pnpm install";
      };
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
      options = {
        deps = deps "fetch.pythonDeps" // {
          type = [
            "set"
            "string"
          ];
        };
        check = strs "modules that must import from the installed layout";
      };
    };
    bundler = {
      tools = [
        buildPkgs.ruby
        sh
      ];
      lock.deps = fetch.gems;
      options = {
        deps = deps "fetch.gems" // {
          type = [
            "set"
            "string"
          ];
        };
        without = strs "Gemfile groups to leave out (default [\"development\" \"test\"])";
        test = strs "command run under `bundle exec` as the test (default: none, test gems are usually in `without`)";
        flags = flags "bundle install";
      };
    };
    deno = {
      tools = [ buildPkgs.deno ];
      lock.deps = fetch.denoDeps;
      options = {
        deps = deps "fetch.denoDeps" // {
          type = [
            "set"
            "string"
          ];
        };
        entry = attrs "bin name -> module path: each becomes bin/<name> running `deno run` on it";
        permissions = strs "permission flags for run and test (default [\"-A\"])";
        check = bool "deno check the entry points (default true)";
        flags = flags "deno run and deno test";
      };
    };
    bun = {
      tools = [
        buildPkgs.bun
        sh
      ];
      lock.deps = fetch.bunDeps;
      dependencies = [ pkgs.nodejs ]; # bin scripts say #!/usr/bin/env node
      options = {
        inherit script;
        deps = deps "fetch.bunDeps" // {
          type = [
            "set"
            "string"
          ];
        };
        flags = flags "bun install";
        compile = attrs "bin name -> entry module: `bun build --compile` single executables instead of installing the tree";
      };
    };
    yarn = {
      tools = [
        buildPkgs.yarn
        buildPkgs.nodejs
        sh
      ];
      lock.deps = fetch.yarnDeps;
      dependencies = [ pkgs.nodejs ]; # bin scripts say #!/usr/bin/env node
      options = {
        inherit script;
        deps = deps "fetch.yarnDeps";
        flags = flags "yarn install";
      };
    };
    npm = {
      tools = [
        buildPkgs.nodejs
        sh
      ];
      lock.deps = fetch.npmDeps;
      dependencies = [ pkgs.nodejs ]; # bin scripts say #!/usr/bin/env node
      options = {
        inherit script;
        deps = deps "fetch.npmDeps";
        flags = flags "npm ci";
      };
    };
  }
