# Development shell: `treefmt` (treefmt.nix). Not part of the package set. Plain nixpkgs.
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShellNoCC {
  packages = [ (import ./treefmt.nix { inherit pkgs; }) ];
}
