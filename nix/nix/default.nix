# Nix master plus the fixes the set needs, branch `repkgs` of github.com/Mic92/nix-1, built by
# nixpkgs' component packaging.
#   https://github.com/NixOS/nix/pull/16459 required: dynamic derivations rebuild after gc
#   https://github.com/NixOS/nix/pull/16465 recommended: CA rebuilds of derivations that see
#     their $out (bootstrap/) do not conflict
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.nixVersions.git.overrideSource (
  pkgs.fetchFromGitHub {
    owner = "Mic92";
    repo = "nix-1";
    rev = "d79f8ae49aedb7c8739d5eeda54aad1f3a0186d0"; # repkgs
    hash = "sha256-oOfVHhrCbe1oaIsw+hpYuPK+Tvy0mTM5rnQx6cbTRWM=";
  }
)
