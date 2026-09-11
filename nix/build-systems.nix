# What `uses = [ "<name>" ]` means: builder/systems/<name>.nu implements the phases, `phases` is the default
# order (build test install unless said otherwise), `tool` (swappable per package as `<name>.tool`)
# and `tools` (a list, or spec -> list) go on PATH, `dependencies` add to
# the package's, `prebuilt` is the package's default for that field, `unsupported` is a reason
# (or null) why no user of it can build on this platform, and `options` are what a
# package may set under `<name>.*`: `{ type; default; doc; }` each, `type` the `builtins.typeOf`
# names allowed, checked at eval time along with the name. The module reads the merged result as
# `options <name>`. Every system has `root`; `deps` (the fetched tree of locked dependencies,
# `lock.deps = fetcher` defaults it to the package's own lock file) and `flags` (extra words on
# the tool's command line) mean the same wherever they exist. `repkgs options` renders this as a
# table. `sh` is for tools that spawn a shell by name (ninja, npm run, libtool).
{
  buildPkgs,
  pkgs,
  platform,
  fetch,
  sh,
}:
let
  opt = type: default: doc: {
    type = if builtins.isList type then type else [ type ];
    inherit default doc;
  };
  str = opt "string";
  optStr = opt [
    "string"
    "null"
  ];
  strs = opt "list";
  bool = opt "bool";
  attrs = opt "set";
  # a derivation, or the placeholder string a dynamic derivation's output is at eval time. The
  # default comes from `lock.deps` (the package's own lock file), null where that is allowed means
  # the source vendors its dependencies
  deps =
    nullable: fetcher:
    opt (
      [
        "set"
        "string"
      ]
      ++ (if nullable then [ "null" ] else [ ])
    ) null "the locked dependencies, fetched (${fetcher}), by default from the package's own lock file";
  flags = tool: strs [ ] "extra arguments for ${tool}";
  # bin scripts say #!/usr/bin/env node, prebuilt .node addons (rollup, esbuild) link libgcc_s.so.1
  nodeDeps = [
    pkgs.nodejs
    pkgs.libgcc-shim
  ];
  script = optStr "build" "package.json script `build` runs (null: none)";
in
builtins.mapAttrs
  (
    name: bs:
    let
      options = {
        root = str "." "directory below the source the project lives in (monorepos, build/cmake)";
      }
      // (if bs ? tool then { tool = opt "set" bs.tool "the package that provides ${name}"; } else { })
      // bs.options;
      extra = if builtins.isFunction (bs.tools or [ ]) then bs.tools else _: bs.tools or [ ];
      # one set per build system, only `lock` options depend on the package
      optionDefaults = builtins.mapAttrs (_: o: o.default) options;
    in
    {
      inherit options;
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
      # what the package's `<name>` record starts from: every option's default, `lock` ones fetched
      defaults =
        if bs ? lock then
          args: optionDefaults // builtins.mapAttrs (_: f: f { inherit (args) source; }) bs.lock
        else
          _: optionDefaults;
      # `tool`: the build system's own program, a package may swap it (`cmake.tool = …`)
      tools = spec: (if bs ? tool then [ spec.${name}.tool ] else [ ]) ++ extra spec;
      dependencies = bs.dependencies or [ ];
      prebuilt = bs.prebuilt or false;
      unsupported = bs.unsupported or null;
      stack = bs.stack or [ ];
    }
  )
  {
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
      options = {
        flags = flags "configure";
        makeFlags = strs [ ] "arguments for every make invocation (build, test, install)";
        installFlags = strs [ ] "arguments for `make install` only";
        configureScript = str "configure" "configure script relative to the project";
        outOfTree = bool true "configure from a separate build directory";
        buildTarget = strs [ ] "make goals for build (empty: the makefile's default goal)";
        testTarget = strs [ "check" ] "make goals for test";
      };
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
      options = {
        defs = attrs { } "-D cache entries. true/false render ON/OFF, packages their store path";
        generator = str "Ninja" "cmake -G";
        flags = flags "cmake at configure time";
        skipTests = strs [ ] "ctest -E regexes";
      };
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
      options = {
        defs = attrs { } "-D options, merged over prefix/libdir/buildtype defaults";
        flags = flags "meson setup";
        skipTests = strs [ ] "regexes on `meson test --list` names";
      };
    };
    python = {
      phases = [
        "build"
        "install"
        "test"
      ]; # tests import the installed module
      # the PEP 517 front end and its deps. Members of the stack itself get only what exists before them
      tool = buildPkgs.cpython;
      stack = with buildPkgs; [
        python-flit-core
        python-packaging
        python-pyproject-hooks
        python-build
        python-installer
      ];
      options = {
        backend = str "setuptools" "PEP 517 backend when pyproject.toml names none: setuptools, flit_core, maturin";
        module = optStr null "module the import test loads (null: the package name with - as _)";
        pytest = bool false "also run pytest on tests/";
      };
    };
    cargo = {
      # `cargo.tool = buildPkgs.rust-bootstrap` for what must exist before llvm and rust are
      # built (formatelf, git). Cross: std for the target is its own package, <tool>-std
      tool = buildPkgs.rust;
      tools = spec: if platform.cross then [ pkgs."${spec.cargo.tool.pname}-std" ] else [ ];
      lock.deps = fetch.cargoVendor;
      options = {
        features = strs [ ] "--features";
        noDefaultFeatures = bool false "--no-default-features";
        flags = flags "cargo build and cargo test";
        skipTests = strs [ ] "cargo test --skip filters (substring of the test path)";
        deps = deps true "fetch.cargoVendor";
      };
    };
    cabal = {
      unsupported = if platform.cross then "ghc-bootstrap only targets the build machine" else null;
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
      options = {
        deps = deps false "fetch.hackageSet" // {
          default = fetch.hackageSet { };
          doc = "hackage repository to solve against, by default the shared set from locks/hackage.toml";
        };
        flags = flags "every cabal subcommand (--flags=…, --allow-newer)";
        exes = strs [ ] "exe components to build and install";
        project = str "" "extra cabal.project text (allow-newer:, constraints:)";
      };
    };
    luarocks = {
      phases = [ "install" ]; # luarocks make builds into --tree
      tool = buildPkgs.luarocks;
      tools = [ sh ];
      options = {
        deps = deps false "fetch.luaRocksSet" // {
          default = fetch.luaRocksSet { inherit (buildPkgs) lua; };
          doc = "rock server directory, by default the shared set from locks/luarocks.toml";
        };
        rockspec = optStr null "rockspec file when the source has several (null: luarocks picks)";
        flags = flags "luarocks make";
      };
    };
    go = {
      tool = buildPkgs.go;
      lock.deps = fetch.goModules;
      options = {
        tags = strs [ ] "-tags";
        ldflags = strs [ ] "-ldflags words (-X main.version=…)";
        packages = strs [ "./..." ] "packages to build";
        testPackages = opt [ "list" "null" ] null "packages to test (null: `packages`)";
        skipTests = strs [ ] "go test -skip regexes";
        deps = deps true "fetch.goModules" // {
          doc = "GOPROXY tree (fetch.goModules, by default from go.sum), or null to build from the source's vendor/";
        };
        cgo = bool true "CGO_ENABLED and external linking";
        flags = flags "go build and go test";
      };
    };
    pnpm = {
      tool = buildPkgs.pnpm;
      tools = [
        buildPkgs.nodejs
        sh
      ];
      lock.deps = fetch.pnpmDeps;
      dependencies = nodeDeps;
      options = {
        inherit script;
        deps = deps true "fetch.pnpmDeps";
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
        deps = deps false "fetch.pythonDeps";
        check = strs [ ] "modules that must import from the installed layout";
      };
    };
    bundler = {
      tool = buildPkgs.ruby;
      tools = [ sh ];
      lock.deps = fetch.gems;
      options = {
        deps = deps false "fetch.gems";
        without = strs [ "development" "test" ] "Gemfile groups to leave out";
        test =
          opt [ "list" "null" ] null
            "command run under `bundle exec` as the test (null: none, test gems are usually in `without`)";
        flags = flags "bundle install";
      };
    };
    deno = {
      tool = buildPkgs.deno;
      lock.deps = fetch.denoDeps;
      options = {
        deps = deps false "fetch.denoDeps";
        entry = attrs { } "bin name -> module path: each becomes bin/<name> running `deno run` on it";
        permissions = strs [ "-A" ] "permission flags for run and test";
        check = bool true "deno check the entry points";
        flags = flags "deno run and deno test";
      };
    };
    bun = {
      tool = buildPkgs.bun;
      tools = [ sh ];
      lock.deps = fetch.bunDeps;
      dependencies = nodeDeps;
      options = {
        inherit script;
        deps = deps false "fetch.bunDeps";
        flags = flags "bun install";
        compile =
          attrs { }
            "bin name -> entry module: `bun build --compile` single executables instead of installing the tree";
      };
    };
    yarn = {
      tool = buildPkgs.yarn;
      tools = [
        buildPkgs.nodejs
        sh
      ];
      lock.deps = fetch.yarnDeps;
      dependencies = nodeDeps;
      options = {
        inherit script;
        deps = deps true "fetch.yarnDeps";
        flags = flags "yarn install";
      };
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
      lock.deps = fetch.hexDeps;
      dependencies = [ pkgs.erlang ]; # escripts say #!/usr/bin/env escript, releases exec erl
      options = {
        deps = deps false "fetch.hexDeps";
        escript = strs [ ] "escripts `mix escript.build` writes, installed into bin/. Empty: a mix release";
        flags = flags "mix compile";
      };
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
      lock.deps = fetch.hexDeps;
      dependencies = [ pkgs.erlang ];
      options = {
        deps = deps false "fetch.hexDeps";
        flags = flags "rebar3 compile";
      };
    };
    npm = {
      tool = buildPkgs.nodejs;
      tools = [ sh ];
      lock.deps = fetch.npmDeps;
      dependencies = nodeDeps;
      options = {
        inherit script;
        deps = deps true "fetch.npmDeps";
        flags = flags "npm ci";
      };
    };
  }
