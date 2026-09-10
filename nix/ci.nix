# What CI builds for one build machine: the whole set as `pkg-<name>` and per foreign cpu as
# `cross-<cpu>-<name>`, treefmt, the seed and the mingw sysroot. flake.nix maps this over its
# systems as `checks`; `nix-build nix/ci.nix -A pkg-jq` works without flakes.
{
  system ? builtins.currentSystem,
  nixpkgs ? <nixpkgs>,
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  crossCpus = [
    "aarch64"
    "riscv64"
    "loongarch64"
    "powerpc64le"
    "x86_64"
  ];

  buildCpu = lib.head (lib.splitString "-" system);
  setFor =
    cpu:
    import ../default.nix {
      inherit system;
      platform = "${cpu}-linux";
    };
  # prebuilt sources exist only for the cpus upstream ships
  evaluates = _: p: (builtins.tryEval p.drvPath).success;
  prefixed = prefix: lib.mapAttrs' (n: v: lib.nameValuePair "${prefix}${n}" v);
  crossSet = cpu: prefixed "cross-${cpu}-" (lib.filterAttrs evaluates (setFor cpu));
in
prefixed "pkg-" (setFor buildCpu)
// lib.mergeAttrsList (map crossSet (lib.filter (cpu: cpu != buildCpu) crossCpus))
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
  mingw-w64 = (import ../bootstrap { inherit system; }).mingw.x86_64.mingw-w64;
}
