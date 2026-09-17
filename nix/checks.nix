# What CI builds for one build machine: every supported package of the set as `pkg-<name>`
# and per other platform as `<platform>-<name>`, separate test suites (tests.separate) as
# `tests-<name>`, tests/builder as `builder-*`, treefmt and the
# seed. x86_64-windows-msvc is not in the default list: the SDK under its toolchain is unfree
# and stays out of the public cache. flake.nix maps this over its systems as `checks`;
# `nix-build nix/checks.nix` without flakes, `-A pkg-jq` for one.
{
  system ? builtins.currentSystem,
  nixpkgs ? import ./nixpkgs.nix,
  platforms ? [
    "x86_64-linux"
    "aarch64-linux"
    "riscv64-linux"
    "loongarch64-linux"
    "powerpc64le-linux"
    "x86_64-windows-gnu"
  ],
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  setFor =
    platform:
    import ../default.nix {
      inherit system platform;
    };
  # nix/package.nix decides `supported` per platform without forcing the derivation
  supported = set: lib.filterAttrs (_: p: p.supported) set;
  prefixed = prefix: lib.mapAttrs' (n: v: lib.nameValuePair "${prefix}${n}" v);
  forPlatform = p: prefixed (if p == system then "pkg-" else "${p}-") (supported (setFor p));
  separateTests = lib.concatMapAttrs (n: p: if p ? tests then { ${n} = p.tests; } else { }) (
    supported (setFor system)
  );
in
lib.mergeAttrsList (map forPlatform platforms)
// prefixed "tests-" separateTests
// prefixed "builder-" (import ../tests/builder { inherit system; })
// {
  treefmt =
    pkgs.runCommand "treefmt-check"
      {
        nativeBuildInputs = [
          (import ../treefmt.nix {
            inherit pkgs;
            evaluates = false;
          })
        ];
      }
      "cp -r ${
        builtins.path {
          path = ../.;
          name = "source";
          filter = p: t: baseNameOf p != ".jj" && lib.cleanSourceFilter p t;
        }
      } src && chmod -R u+w src && cd src && treefmt --ci --tree-root . && touch $out";
  inherit
    (import ../pkgs/se/seed/build.nix {
      inherit nixpkgs system;
      buildSystem = system;
    })
    seed
    ;
}
