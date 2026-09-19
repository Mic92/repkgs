# bench/eval.nu's expressions: `pairs` (our supported packages that have a nixpkgs twin),
# `ours`/`theirs` <names-json> (those as one attrset of derivations, what nix-instantiate walks)
let
  repo = ../.;
  ours = import repo { };
  nixpkgs = import (import (repo + "/nix/nixpkgs.nix")) {
    config.allowUnfree = true;
    overlays = [ ];
  };
  inherit (nixpkgs) lib;
  # our name -> nixpkgs attribute path where they differ
  alias = {
    "7zip" = "_7zz";
    bdw-gc = "boehmgc";
    bindgen = "rust-bindgen";
    blake3 = "libblake3";
    cabal = "cabal-install";
    clang21 = "clang_21";
    cpython = "python3";
    cpython314 = "python314";
    googletest = "gtest";
    grep = "gnugrep";
    libjpeg-turbo = "libjpeg";
    libomp = "llvmPackages.openmp";
    libusb = "libusb1";
    lld21 = "lld_21";
    llvm21 = "llvm_21";
    llvm22 = "llvm_22";
    luacheck = "luaPackages.luacheck";
    nlohmann-json = "nlohmann_json";
    rpds-py = "python3Packages.rpds-py";
    rust = "rustc";
    sed = "gnused";
  }
  // lib.genAttrs' [
    "build"
    "cython"
    "flit-core"
    "hatch-vcs"
    "hatchling"
    "installer"
    "packaging"
    "pathspec"
    "pluggy"
    "pyproject-hooks"
    "setuptools"
    "setuptools-scm"
    "trove-classifiers"
  ] (p: lib.nameValuePair "python-${p}" "python3Packages.${p}");
  theirsOf = n: lib.attrByPath (lib.splitString "." (alias.${n} or n)) null nixpkgs;
  hasDrv =
    v: v != null && (builtins.tryEval (v.drvPath or null)).success && (v.drvPath or null) != null;
  pairs = builtins.filter (p: hasDrv (theirsOf p.our)) (
    map
      (n: {
        our = n;
        np = alias.${n} or n;
      })
      (builtins.filter (n: ours.${n}.supported or false && ours.${n} ? drvPath) (builtins.attrNames ours))
  );
  # builtins only: timing `ours` must not load nixpkgs' lib
  pick =
    f: names:
    builtins.listToAttrs (
      map (n: {
        name = n;
        value = f n;
      }) (builtins.fromJSON names)
    );
in
{
  inherit pairs;
  ours = pick (n: ours.${n});
  theirs = pick theirsOf;
}
