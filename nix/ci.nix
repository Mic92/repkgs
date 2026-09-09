# What CI builds for one build machine: a native package selection, the cross smoke set per foreign
# cpu, treefmt, the seed and the mingw sysroot. flake.nix maps this over its systems as `checks`;
# `nix-build nix/ci.nix -A jq` works without flakes (nixpkgs from NIX_PATH then).
{
  system ? builtins.currentSystem,
  nixpkgs ? <nixpkgs>,
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  native = [
    "jq"
    "fd"
    "fzf"
    "ripgrep"
    "cpython"
    "cmake"
    "curl"
    "glib"
    "openssl"
    "perl"
    "qemu"
    "uglify-js"
    "navidrome"
    "svgo"
    "maturin"
    "pkgs-cache"
    "dbmate"
    "create-hono"
    "ruby-lsp"
    "copier"
  ];
  cross = [
    "zlib"
    "pcre2"
    "jq"
    "fd"
    "fzf"
  ];
  crossCpus = [
    "aarch64"
    "riscv64"
    "loongarch64"
    "powerpc64le"
    "x86_64"
  ];

  set = import ../default.nix { inherit system; };
  setFor =
    cpu:
    import ../default.nix {
      inherit system;
      platform = "${cpu}-linux";
    };
  buildCpu = lib.head (lib.splitString "-" system);
in
lib.genAttrs native (n: set.${n})
// lib.listToAttrs (
  lib.concatMap (cpu: map (n: lib.nameValuePair "cross-${cpu}-${n}" (setFor cpu).${n}) cross) (
    lib.filter (cpu: cpu != buildCpu) crossCpus
  )
)
// {
  treefmt =
    pkgs.runCommand "treefmt-check"
      {
        nativeBuildInputs = [ (import ../treefmt.nix { inherit pkgs; }) ];
      }
      "cp -r ${
        builtins.path {
          path = ../.;
          name = "source";
        }
      } src && chmod -R u+w src && cd src && treefmt --ci && touch $out";
  inherit (import ../pkgs/se/seed/build.nix { inherit nixpkgs system; }) seed;
  mingw-w64 = set.bootstrap.mingw.x86_64.mingw-w64;
}
