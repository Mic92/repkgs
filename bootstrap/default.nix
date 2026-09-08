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
  # run.nu + lib.nu + the one recipe, laid out as in the tree (bootstrap/, pkgs/x/x/) so the recipe's
  # relative `use ../../bootstrap/lib.nu` resolves, and an edit to one recipe rebuilds only its step
  recipe =
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
        outputs = [ "out" ];
        inherit (platform)
          triple
          cpu
          libc
          interp
          ;
        karch = platform.names.kernel;
        flags = toString platform.flags;
        seed = seedPath;
        builder = "${seedPath}/bin/nu";
        args = [
          "--no-config-file"
          "${r.path}/bootstrap/run.nu"
          "${r.path}/${r.rel}"
        ];
        PATH = builtins.concatStringsSep ":" (map (t: "${t}/bin") (extraTools ++ tools ++ [ seedPath ]));
        # the seed's bison is relocated: tell it where its m4 and skeletons are
        M4 = "m4";
        BISON_PKGDATADIR = "${seedPath}/share/bison";
        jig = builtins.path {
          path = pkg "jig" + "/src";
          name = "jig-src";
          filter = p: _: builtins.match ".*\\.(cc|h)" p != null;
        };
        blake3 = source "blake3";
        zstd = source "zstd";
        json_hpp = source "nlohmann-json";
        inherit (builtins) storeDir;
        crt_interp = pkg "crt-interp" + "/src/crt_interp.c";
        launch = pkg "launch" + "/src/launch.cc";
      }
      // env
      // removeAttrs args [ "recipe" ]
    );

  # stage0: the musl toolchain for the build machine (our own jig/launch are static against it,
  # and it gives stage1 a native `cc`). sh, make and the GNU text tools come from the seed.
  stage0 =
    let
      platform = platforms.forSystem system "musl";
      run = mkStage platform { } [ ];
      sysroot =
        parts:
        run "sysroot" {
          inherit parts;
          resource = compiler-rt;
        };
      musl-headers = run "musl" {
        src = source "musl";
        headersOnly = "1";
      };
      compiler-rt = run "compiler-rt" {
        src = source "llvm";
        libcHeaders = musl-headers;
        list = pkg "llvm" + "/builtins-${platform.cpu}.txt";
      };
      musl = run "musl" {
        src = source "musl";
        inherit compiler-rt;
      };
      linux-headers = run "linux-headers" {
        src = source "linux";
        sysroot = sysroot [ musl ];
      };
      runtimes = run "runtimes" {
        src = source "llvm";
        sysroot = sysroot [
          musl
          linux-headers
        ];
      };
      full = sysroot [
        musl
        linux-headers
        runtimes
      ];
      jig = run "jig" { sysroot = full; };
      cc = mkStage platform (cached jig) [ ] "cc" {
        sysroot = full;
        prebuilt = jig;
      };
    in
    {
      inherit
        platform
        compiler-rt
        musl
        linux-headers
        runtimes
        jig
        cc
        ;
    };

  stage1 =
    cpu:
    let
      platform = platforms.glibc.${cpu};
      run = mkStage platform (cached stage0.jig) [ stage0.cc ];
      sysroot =
        parts:
        run "sysroot" {
          inherit parts;
          resource = compiler-rt;
        };
      glibcArgs = {
        src = source "glibc";
        patches = [ (pkg "glibc" + "/glibc-gconv-relative.patch") ];
        linuxHeaders = linux-headers;
        configureFlags = toString platform.glibcConfigure;
      };
      linux-headers = run "linux-headers" { src = source "linux"; };
      glibc-headers = run "glibc" (glibcArgs // { headersOnly = "1"; });
      compiler-rt = run "compiler-rt" {
        src = source "llvm";
        libcHeaders = glibc-headers;
        linuxHeaders = linux-headers;
        list = pkg "llvm" + "/builtins-${cpu}.txt";
      };
      # the C.UTF-8 locale is compiled by running the fresh localedef, so only where it can run
      glibc = run "glibc" (
        glibcArgs
        // {
          inherit compiler-rt;
          interp =
            if platform.triple == (platforms.forSystem system "glibc").triple then platform.interp else "";
        }
      );
      runtimes = run "runtimes" {
        src = source "llvm";
        sysroot = sysroot [
          glibc
          linux-headers
        ];
      };
      cc = run "cc" {
        sysroot = sysroot [
          glibc
          linux-headers
          runtimes
        ];
        native = stage0.cc;
        prebuilt = stage0.jig;
      };
      launch = mkStage platform (cached stage0.jig) [ cc ] "launch" { };
    in
    {
      inherit
        platform
        linux-headers
        compiler-rt
        glibc
        runtimes
        cc
        launch
        ;
    };
in
{
  seed = seedPath;
  inherit stage0 source;
  stage1 = builtins.mapAttrs (cpu: _: stage1 cpu) platforms.glibc;
}
