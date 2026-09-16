# Nix master plus the fixes the set needs, branch `repkgs` of github.com/Mic92/nix-1, built by
# nixpkgs' component packaging.
#   https://github.com/NixOS/nix/pull/16459 required: dynamic derivations rebuild after gc
#   https://github.com/NixOS/nix/pull/16465 recommended: CA rebuilds of derivations that see
#     their $out (bootstrap/) do not conflict
#   https://github.com/NixOS/nix/pull/16477 recommended: a CA rebuild that differs from a
#     garbage-collected earlier output replaces its build trace instead of failing
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.nixVersions.git.overrideSource (
  pkgs.fetchFromGitHub {
    owner = "Mic92";
    repo = "nix-1";
    rev = "e6c24e710343d0485995d1a67c6f4971d698bbca"; # repkgs
    hash = "sha256-XVtq1d7UwIj4/J3g1uaQkEq6bdu0p85JHZEFlm9qukg=";
  }
)
