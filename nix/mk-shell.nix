# A development shell made of this set's packages, for a flake that wants the tools without
# nixpkgs' mkShell. `nix develop` never builds it: nix swaps the builder's arguments for its own
# get-env.sh, builds that, and reads the environment back out. Two consequences shape the
# derivation below.
#
#   - The builder must be called `bash`. develop.cc refuses anything else: "'nix develop' only
#     works on derivations that use 'bash' as their builder". A nu builder, which every package
#     of this set uses, cannot be entered.
#   - Everything the shell offers is a plain environment variable here. There is no setup script
#     and no stdenv, so PATH and the probe paths are written out rather than derived from
#     buildInputs. get-env.sh sources `$stdenv/setup` only when `stdenv` is set, and it is not.
#
# `nix develop` prepends PATH to the caller's rather than replacing it, and evaluates
# `shellHook` on entry.
{
  platform,
  toolchain,
  bash,
  lib,
}:
{
  name ? "repkgs-shell",
  # their bin/ goes on PATH, their lib/pkgconfig on PKG_CONFIG_PATH
  packages ? [ ],
  # the set's own cc wrapper, so `cc`, `c++` and the linker in the shell are the ones every
  # package here was built with. false for a shell that compiles nothing
  cc ? true,
  # more variables, and a script to evaluate on entry
  env ? { },
  shellHook ? "",
}:
let
  all = packages ++ lib.on cc [ toolchain ];
  under = sub: lib.join ":" (map (p: "${p}/${sub}") all);
  shell = derivation (
    {
      inherit name shellHook;
      inherit (platform) system;
      # get-env.sh walks `$outputs` to find where to write, and nix puts that variable in the
      # environment only for a derivation that names its outputs. Without it the build writes
      # nothing and `nix develop` fails with "failed to produce output path".
      outputs = [ "out" ];
      builder = "${bash}/bin/bash";
      # only reached by building the shell, which no one wants
      args = [
        "-c"
        "echo 'this is a dev shell, enter it with `nix develop`' >&2; exit 1"
      ];
      PATH = under "bin";
      PKG_CONFIG_PATH = under "lib/pkgconfig";
      CMAKE_PREFIX_PATH = lib.join ":" (map toString all);
    }
    // env
  );
in
shell
// {
  # Everything the shell needs, as one derivation that can be built. nixpkgs' mkShell carries
  # the same attribute, and a NixOS test that must run offline realises it to get the closure
  # into the guest's store.
  inputDerivation = derivation {
    name = "${name}-inputs";
    inherit (platform) system;
    builder = "${bash}/bin/bash";
    args = [
      "-c"
      ''printf '%s\n' $paths > $out''
    ];
    paths = all;
  };
}
