# From the seed to a configured `cc` per platform, by running the same recipes twice:
#   stage0  musl,  PATH = seed              -> jig + cc for the build machine
#   stage1  glibc, PATH = stage0 cc + seed   -> cc-<platform> and launch for every platform
# Each derivation is `nu run.nu <recipe>.nu`. Recipes live with their package (pkgs/<name>/bootstrap.nu,
# pkgs/ll/llvm/{compiler-rt,runtimes,cc}.nu) or here (sysroot.nu). Inputs are
# structured attrs, run.nu exports them as environment variables for the recipe.
{
  seed ? null,
  system ? builtins.currentSystem,
}:
let
  platforms = import ../nix/platforms.nix;
  hardening = import ../nix/hardening.nix;
  pkg = name: ../pkgs + "/${builtins.substring 0 2 name}/${name}";

  seedPath =
    if seed == null then
      (source' "seed").fetch system
    else if builtins.isString seed then
      builtins.storePath seed
    else
      seed;
  # the seed's own sources.toml is read without an unpacker: it is the unpacker
  sources = import ../nix/sources.nix {
    unpacker = seedPath;
    inherit system;
  };
  source' =
    name:
    (if name == "seed" then import ../nix/sources.nix { unpacker = null; } else sources) (
      pkg name + "/sources.toml"
    );
  source = name: (source' name).default;

  recipes = {
    sysroot = ./sysroot.nu;
    compiler-rt = pkg "llvm" + "/compiler-rt.nu";
    runtimes = pkg "llvm" + "/runtimes.nu";
    cc = pkg "llvm" + "/cc.nu";
    linux-headers = pkg "linux" + "/bootstrap.nu";
  };
  # sources a recipe compiles from this repo, per recipe so that editing jig rebuilds jig and cc,
  # not glibc (and eval touches them once, not per stage derivation)
  json_hpp = source "nlohmann-json";
  recipeInputs = {
    jig = {
      jig = builtins.path {
        path = pkg "jig" + "/src";
        name = "jig-src";
        filter = p: _: builtins.match ".*\\.(cc|h)" p != null;
      };
      blake3 = source "blake3";
      zstd = source "zstd";
      inherit json_hpp;
      inherit (builtins) storeDir;
    };
    launch = {
      launch = pkg "launch" + "/src/launch.cc";
      inherit json_hpp;
    };
    cc.crt_interp = pkg "crt-interp" + "/src/crt_interp.c";
    dlaudit.dlaudit = pkg "dlaudit" + "/src/dlaudit.cc";
  };
  # run.nu + lib.nu + the one recipe, laid out as in the tree (bootstrap/, pkgs/x/x/) so the recipe's
  # relative `use ../../bootstrap/lib.nu` resolves, and an edit to one recipe rebuilds only its step
  recipe' =
    name:
    let
      file = recipes.${name} or (pkg name + "/bootstrap.nu");
      rel = if name == "sysroot" then "bootstrap/${name}.nu" else "pkgs/x/x/${name}.nu";
    in
    {
      inherit rel;
      path = derivation {
        name = "recipe-${name}";
        inherit system;
        builder = "${seedPath}/bin/nu";
        args = [
          "--no-config-file"
          "-c"
          "mkdir $\"($env.out)/bootstrap\" $\"($env.out)/pkgs/x/x\"; cp ${./run.nu} $\"($env.out)/bootstrap/run.nu\"; cp ${./lib.nu} $\"($env.out)/bootstrap/lib.nu\"; cp ${file} $\"($env.out)/${rel}\""
        ];
        preferLocalBuild = true;
      };
    };
  # memoised: one attrset lookup per use instead of a fresh derivation thunk per stage call
  recipeDrvs = builtins.listToAttrs (
    map
      (n: {
        name = n;
        value = recipe' n;
      })
      (
        builtins.attrNames recipes
        ++ [
          "musl"
          "glibc"
          "jig"
          "launch"
          "dlaudit"
          "gnu"
          "toybox"
          "dash"
          "python"
        ]
      )
  );
  recipe = name: recipeDrvs.${name} or (recipe' name);

  # Once stage0 has built jig, every later clang call goes through the compile cache: jig's
  # bin/clang shadows the seed's, JIG_CC names the real one. Content identity so that editing a
  # recipe (new store hashes everywhere, same bytes) still hits.
  cached = jig: {
    tools = [ jig ];
    env = {
      JIG_CC = "${seedPath}/bin/clang";
      JIG_STORE_IDENTITY = "content";
    };
  };

  configSite = "${../nix/config.site}";
  seedBin = "${seedPath}/bin";

  # mkStage <platform> <tools>  ->  `run <recipe> <env>` for that platform with those tools on PATH
  mkStage =
    platform:
    {
      tools ? [ ],
      env ? { },
    }:
    extraTools: recipeName: args:
    let
      r = recipe (args.recipe or recipeName); # several GNU tools share gnu.nu
    in
    derivation (
      {
        name =
          recipeName
          + (if env ? headersOnly then "-headers" else "")
          + (if platform.libc == "musl" then "" else "-${platform.name}");
        inherit system;
        __structuredAttrs = true;
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputs = [ "out" ];
        inherit (platform)
          triple
          cpu
          libc
          os
          binfmt
          interp
          ;
        karch = platform.names.kernel;
        # -march plus the cpu's own hardening (cf-protection, BTI): baked into jig.conf and used by
        # every bootstrap compile. The rest of nix/hardening.nix is per package (builder/env.nu)
        flags = toString (
          platform.march ++ hardening.enabledFlags (hardening.forPlatform platform) hardening.cpuOnly
        );
        seed = seedPath;
        builder = "${seedPath}/bin/nu";
        args = [
          "--no-config-file"
          "${r.path}/bootstrap/run.nu"
          "${r.path}/${r.rel}"
        ];
        PATH = builtins.concatStringsSep ":" (map (t: "${t}/bin") (extraTools ++ tools) ++ [ seedBin ]);
        # the seed's bison is relocated: tell it where its m4 and skeletons are
        M4 = "m4";
        BISON_PKGDATADIR = "${seedPath}/share/bison";
        CONFIG_SITE = configSite;
      }
      // (recipeInputs.${recipeName} or { })
      // env
      // removeAttrs args [ "recipe" ]
    );

  # One toolchain chain, the same for every platform: libc headers -> compiler-rt builtins -> libc
  # -> (kernel headers) -> libc++/libunwind -> configured cc. What differs per libc is where
  # headers+libc come from (a recipe run twice, or on msvc a fetched SDK that also is the C++
  # library) and whether Linux headers are part of the sysroot.
  chain =
    {
      platform,
      run, # mkStage for this platform with its tools
      libcRecipe ? null, # "musl" | "glibc"; run twice, headersOnly first
      libcArgs ? { },
      libcGiven ? null, # instead of libcRecipe: headers, libc and C++ library already there (an SDK)
      linuxHeaders ? null, # in compiler-rt's include path and the sysroot; null off Linux and in stage0 (added later)
      extraParts ? [ ], # sysroot members after libc that are not compiler-rt inputs (stage0's linux headers)
      ccArgs ? { },
    }:
    let
      given = libcGiven != null;
      libcStep = args: if given then libcGiven else run libcRecipe (libcArgs // args);
      sysroot =
        parts:
        run "sysroot" {
          parts = builtins.filter (p: p != null) parts;
          resource = compiler-rt;
        };
      # builtins-<cpu>.txt for Linux, builtins-<cpu>-<os>.txt otherwise (pkgs/ll/llvm/update.nu)
      list =
        pkg "llvm"
        + "/builtins-${platform.cpu}${if platform.os == "linux" then "" else "-${platform.os}"}.txt";
      compiler-rt = run "compiler-rt" (
        {
          src = source "llvm";
          libcHeaders = libcStep { headersOnly = "1"; };
          inherit list;
        }
        // (if linuxHeaders == null then { } else { inherit linuxHeaders; })
      );
      libc = libcStep { inherit compiler-rt; };
      base = [
        libc
        linuxHeaders
      ]
      ++ extraParts;
      # libc++, libc++abi, libunwind. An SDK brings its own C++ library
      runtimes =
        if given then
          null
        else
          run "runtimes" {
            src = source "llvm";
            sysroot = sysroot base;
          };
      full = sysroot (base ++ [ runtimes ]);
      cc = run "cc" ({ sysroot = full; } // ccArgs);
    in
    {
      inherit
        platform
        compiler-rt
        libc
        runtimes
        cc
        ;
      sysroot = full;
    };

  # stage0: the musl toolchain for the build machine (our own jig/launch are static against it,
  # and it gives stage1 a native `cc`). sh, make and the GNU text tools come from the seed. Linux
  # headers install with musl's own tools here, so they come after libc.
  stage0 =
    let
      platform = platforms.forSystem system "musl";
      run = mkStage platform { } [ ];
      c = chain {
        inherit platform run;
        libcRecipe = "musl";
        libcArgs.src = source "musl";
        extraParts = [ linux-headers ];
      };
      linux-headers = run "linux-headers" {
        src = source "linux";
        sysroot = run "sysroot" {
          parts = [ c.libc ];
          resource = c.compiler-rt;
        };
      };
      jig = run "jig" { inherit (c) sysroot; };
    in
    c
    // {
      inherit jig linux-headers;
      musl = c.libc;
      cc = mkStage platform (cached jig) [ ] "cc" {
        inherit (c) sysroot;
        prebuilt = jig;
      };
    };

  cross = platform: mkStage platform (cached stage0.jig) [ stage0.cc ];
  buildPlatform = platforms.forSystem system "glibc";
  # cc-build: the build machine's glibc cc, what rust's host libstd and CC_FOR_BUILD users expect
  crossCc =
    platform:
    {
      prebuilt = stage0.jig;
    }
    // (if platform == buildPlatform then { } else { native = (stage1 buildPlatform.cpu).cc; });

  stage1 =
    cpu:
    let
      platform = platforms.glibc.${cpu};
      run = cross platform;
      linux-headers = run "linux-headers" { src = source "linux"; };
      c = chain {
        inherit platform run;
        libcRecipe = "glibc";
        libcArgs = {
          src = source "glibc";
          patches = [
            (pkg "glibc" + "/glibc-gconv-relative.patch")
            (pkg "glibc" + "/glibc-ppc64le-clang.patch")
            (pkg "glibc" + "/glibc-debug-after-misc.patch")
            (pkg "glibc" + "/glibc-verneed-dst.patch")
          ];
          linuxHeaders = linux-headers;
          # the C.UTF-8 locale is compiled by running the fresh localedef, so only where it can run
          locale = platform.triple == (platforms.forSystem system "glibc").triple;
        };
        linuxHeaders = linux-headers;
        ccArgs = crossCc platform;
      };
    in
    c
    // {
      glibc = c.libc;
      inherit linux-headers;
      launch = mkStage platform (cached stage0.jig) [ c.cc ] "launch" { };
      dlaudit = mkStage platform (cached stage0.jig) [ c.cc ] "dlaudit" { };
    };

  # The non-Linux chains: libc, C++ library and SDK stubs come fetched (`sdk`), compiler-rt
  # builtins are ours, no runtimes step. windows-sdk needs the native set's 7zip, so nix/set.nix
  # passes it in. apple-sdk unpacks with the seed alone.
  sdkChain =
    platform: sdk:
    chain {
      inherit platform;
      run = cross platform;
      libcGiven = sdk;
      ccArgs = crossCc platform;
    };
  msvc = cpu: sdkChain platforms.msvc.${cpu};
  macos =
    cpu:
    let
      platform = platforms.macos.${cpu};
    in
    sdkChain platform (cross platform "apple-sdk" { src = source "apple-sdk"; });
in
{
  seed = seedPath;
  inherit
    stage0
    source
    msvc
    macos
    ;
  stage1 = builtins.mapAttrs (cpu: _: stage1 cpu) platforms.glibc;
}
