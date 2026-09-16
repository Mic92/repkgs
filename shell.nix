# Development shell: `treefmt` (treefmt.nix) and what uptrack shells out to. Not part of the
# package set. Plain nixpkgs (nix/nixpkgs.nix).
{
  pkgs ? import (import ./nix/nixpkgs.nix) { },
}:
pkgs.mkShell {
  packages = [
    (import ./treefmt.nix { inherit pkgs; })
    pkgs.nushell
    pkgs.libarchive # bsdtar, uptrack's prefetch unpacks like nix/sources.nix does
    pkgs.taplo # uptrack writes sources.toml the way treefmt formats it
  ];
}
