# From the seed to a configured `cc` per platform:
#   stage0  seed clang, musl    -> jig and a cc for the build machine
#   stage1  seed clang, glibc   -> a cc to host cmake and llvm (clang+lld, all targets, toolchain.nu)
#   stage2  our clang           -> compiler-rt, libc, libc++, cc and launch for every platform
# Each derivation is `nu run.nu <recipe>.nu` with structured attrs as its environment. Recipes
# live with their package (pkgs/<name>/bootstrap.nu, pkgs/ll/llvm/*.nu) or here (sysroot.nu).
{
  seed ? null,
  system ? builtins.currentSystem,
}:
let
  platforms = import ../nix/platforms.nix;
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
    llvm = pkg "llvm" + "/toolchain.nu";
    cmake = pkg "cmake-bootstrap" + "/bootstrap.nu";
    linux-headers = pkg "linux" + "/bootstrap.nu";
  };
  # per recipe, so that editing jig rebuilds jig and cc, not glibc. One thunk each: eval forces a
  # source once however many stage derivations use it
  json_hpp = source "nlohmann-json";
  llvmSrc = source "llvm";
  recipeInputs = {
    jig = {
      jig = builtins.path {
        path = pkg "jig" + "/src";
        name = "jig-src";
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
    cc = {
      crt_interp = pkg "crt-interp" + "/src/crt_interp.c";
      reloc = builtins.path {
        name = "reloc";
        path = pkg "crt-interp" + "/src";
        filter = p: _: builtins.match "reloc.*" (baseNameOf p) != null;
      };
    };
    dlaudit.dlaudit = pkg "dlaudit" + "/src/dlaudit.cc";
    llvm = {
      src = llvmSrc;
      zstd = source "zstd";
      zlib = source "zlib";
      patches = [
        (pkg "llvm" + "/upstream-x86-vastart-stack-probe.patch")
        (pkg "llvm" + "/jig-absent-log.patch")
      ];
      targets = (import (pkg "llvm" + "/defs.nix")).LLVM_TARGETS_TO_BUILD;
    };
    cmake.src = source "cmake-bootstrap";
    compiler-rt.src = llvmSrc;
    runtimes.src = llvmSrc;
    linux-headers.src = source "linux";
    musl.src = source "musl";
    mingw-w64.src = source "mingw-w64";
    apple-sdk.src = source "apple-sdk";
    glibc = {
      src = source "glibc";
      patches = map (p: pkg "glibc" + "/${p}") [
        "glibc-prefix-relative.patch"
        "upstream-ppc64le-clang.patch"
        "upstream-debug-after-misc.patch"
        "upstream-verneed-dst.patch"
        "glibc-unwind-origin.patch"
        "glibc-tzdir-etc-zoneinfo.patch"
        "upstream-const-generic-extension.patch"
      ];
    };
  };
  # the recipe plus what it imports, laid out as in the tree (bootstrap/, builder/, pkgs/x/x/) so
  # `use ../../bootstrap/lib.nu` resolves and an edit to one recipe rebuilds only its step
  recipe' =
    name:
    let
      file = recipes.${name} or (pkg name + "/bootstrap.nu");
      rel = if name == "sysroot" then "bootstrap/${name}.nu" else "pkgs/x/x/${name}.nu";
      layout = {
        "bootstrap/run.nu" = ./run.nu;
        "bootstrap/lib.nu" = ./lib.nu;
        "builder/glob.nu" = ../builder/glob.nu;
        "builder/log.nu" = ../builder/log.nu;
        ${rel} = file;
      };
    in
    {
      inherit rel;
      path = mkDrv {
        name = "recipe-${name}";
        inherit system;
        builder = "${seedPath}/bin/nu";
        layout = builtins.toJSON layout;
        args = [
          "--no-config-file"
          "-c"
          "$env.layout | from json | items {|rel, src| mkdir ($\"($env.out)/($rel)\" | path dirname); cp $src $\"($env.out)/($rel)\" }"
        ];
        preferLocalBuild = true;
      };
    };
  recipeDrvs = builtins.mapAttrs (n: _: recipe' n) (recipes // recipeInputs);
  recipe = name: recipeDrvs.${name};

  # `derivation` minus the per-output and override plumbing: these are single-output leaves
  mkDrv =
    attrs:
    let
      strict = builtins.derivationStrict attrs;
    in
    attrs
    // {
      type = "derivation";
      outputName = "out";
      outPath = strict.out;
      inherit (strict) drvPath;
    };

  common = {
    inherit system;
    __structuredAttrs = true;
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputs = [ "out" ];
    seed = seedPath;
    builder = "${seedPath}/bin/nu";
    JIG_STORE_IDENTITY = "content";
    M4 = "m4";
    BISON_PKGDATADIR = "${seedPath}/share/bison";
    CONFIG_SITE = "${../nix/config.site}";
  };

  # `(mkStage stage) extraTools recipe args`: one recipe run. PATH is extraTools (jig's clang shim
  # first once it exists), stage.tools, the seed. JIG_CC is the clang behind the shim
  mkStage =
    {
      platform,
      clang ? seedPath, # whose bin/clang compiles, and what cc.nu points jig.conf at
      tools ? [ ],
      suffix ? "-${platform.name}",
    }:
    let
      perStage = common // {
        inherit (platform)
          clangTarget
          cpu
          libc
          os
          binfmt
          interp
          ;
        karch = platform.names.kernel;
        site_libc = platform.libc;
        flags = toString platform.march;
        llvm = clang;
        JIG_CC = "${clang}/bin/clang";
      };
      binPath = ts: builtins.concatStringsSep ":" (map (t: "${t}/bin") ts);
      basePath = binPath (tools ++ [ seedPath ]);
    in
    extraTools: recipeName: args:
    let
      r = recipe recipeName;
    in
    mkDrv (
      perStage
      // {
        name = recipeName + (if args ? headersOnly then "-headers" else "") + suffix;
        args = [
          "--no-config-file"
          "${r.path}/bootstrap/run.nu"
          "${r.path}/${r.rel}"
        ];
        PATH = if extraTools == [ ] then basePath else "${binPath extraTools}:${basePath}";
      }
      // (recipeInputs.${recipeName} or { })
      // args
    );

  # libc headers -> compiler-rt -> libc -> (kernel headers) -> libc++/libunwind -> sysroot -> cc.
  # The libc is a recipe run twice (headersOnly first) or `libcGiven`, an SDK that also brings
  # the C++ library.
  chain =
    {
      platform,
      run,
      libcRecipe ? null,
      libcArgs ? { },
      libcGiven ? null,
      linuxHeaders ? null,
      extraParts ? [ ],
      ccArgs ? { },
    }:
    let
      given = libcGiven != null;
      libcStep = args: if given then libcGiven else run [ ] libcRecipe (libcArgs // args);
      sysroot =
        parts:
        run [ ] "sysroot" {
          parts = builtins.filter (p: p != null) parts;
          resource = compiler-rt;
        };
      list =
        pkg "llvm" + "/builtins-${if platform.os == "linux" then platform.cpu else platform.name}.txt";
      compiler-rt = run [ ] "compiler-rt" (
        {
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
      runtimes = if given then null else run [ ] "runtimes" { sysroot = sysroot base; };
      full = sysroot (base ++ [ runtimes ]);
      cc = run [ ] "cc" ({ sysroot = full; } // ccArgs);
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

  linuxChain =
    platform: run: ccArgs:
    let
      linux-headers = run [ ] "linux-headers" { };
      c = chain {
        inherit platform run ccArgs;
        libcRecipe = "glibc";
        libcArgs = {
          linuxHeaders = linux-headers;
          # C.UTF-8 is compiled by running the fresh localedef
          locale = platform.clangTarget == buildPlatform.clangTarget;
        };
        linuxHeaders = linux-headers;
      };
    in
    c
    // {
      glibc = c.libc;
      inherit linux-headers;
      launch = run [ c.cc ] "launch" { };
      dlaudit = run [ c.cc ] "dlaudit" { };
    };

  # no jig yet. Linux headers install with musl's own tools here, so they come after libc
  stage0 =
    let
      platform = platforms.forSystem system "musl";
      run = mkStage {
        inherit platform;
        suffix = "";
      };
      c = chain {
        inherit platform run;
        libcRecipe = "musl";
        extraParts = [ linux-headers ];
      };
      linux-headers = run [ ] "linux-headers" {
        sysroot = run [ ] "sysroot" {
          parts = [ c.libc ];
          resource = c.compiler-rt;
        };
      };
      jig = run [ ] "jig" { inherit (c) sysroot; };
    in
    c
    // {
      inherit jig linux-headers;
      musl = c.libc;
      cc = run [ jig ] "cc" {
        inherit (c) sysroot;
        prebuilt = jig;
      };
    };

  buildPlatform = platforms.forSystem system "glibc";

  stage1 =
    let
      run = mkStage {
        platform = buildPlatform;
        tools = [
          stage0.jig
          stage0.cc
        ];
        suffix = "-boot";
      };
      c = linuxChain buildPlatform run { prebuilt = stage0.jig; };
      cmake = run [ c.cc ] "cmake" { inherit (c) sysroot; };
    in
    c
    // {
      inherit cmake;
      llvm = run [
        cmake
        c.cc
      ] "llvm" { inherit (c) sysroot; };
    };

  # stage2. stage1's cc stays on PATH as the host compiler (HOSTCC, cc-build)
  chainFor =
    platform:
    {
      sdk ? null, # windows-sdk needs the native set's 7zip, nix/set.nix passes it in
    }:
    let
      run = mkStage {
        inherit platform;
        clang = stage1.llvm;
        tools = [
          stage0.jig
          stage1.llvm
          stage1.cc
        ];
      };
      ccArgs = {
        prebuilt = stage0.jig;
      }
      // (if platform == buildPlatform then { } else { native = nativeCc; });
      given =
        g:
        chain {
          inherit platform run ccArgs;
          libcGiven = g;
        };
    in
    {
      glibc = linuxChain platform run ccArgs;
      msvc = given sdk;
      apple = given (run [ ] "apple-sdk" { });
      mingw = chain {
        inherit platform run ccArgs;
        libcRecipe = "mingw-w64";
      };
    }
    .${platform.libc};
  toolchain = builtins.mapAttrs (_: chainFor) platforms.byName;
  nativeCc = (toolchain.${buildPlatform.name} { }).cc;
in
{
  seed = seedPath;
  inherit
    stage0
    stage1
    toolchain
    source
    ;
  inherit (stage1) llvm;
  # the linux toolchains by cpu (README)
  stage2 = builtins.listToAttrs (
    map (p: {
      name = p.cpu;
      value = toolchain.${p.name} { };
    }) (builtins.filter (p: p.os == "linux") (builtins.attrValues platforms.byName))
  );
}
