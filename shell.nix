# Development shell: `treefmt` (treefmt.nix) and what uptrack shells out to. Not part of the
# package set. Plain nixpkgs.
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell {
  packages = [
    (import ./treefmt.nix { inherit pkgs; })
    pkgs.nushell
    pkgs.libarchive # bsdtar, uptrack's prefetch unpacks like nix/sources.nix does
  ];
}
