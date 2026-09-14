# Development shell: `treefmt` (treefmt.nix) and what uptrack shells out to. Not part of the
# package set. Plain nixpkgs, pinned via flake.lock so `nix-shell` matches `nix develop`.
{
  pkgs ?
    let
      locked = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked;
    in
    import (fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/${locked.rev}.tar.gz";
      sha256 = locked.narHash;
    }) { },
}:
pkgs.mkShell {
  packages = [
    (import ./treefmt.nix { inherit pkgs; })
    pkgs.nushell
    pkgs.libarchive # bsdtar, uptrack's prefetch unpacks like nix/sources.nix does
    pkgs.taplo # uptrack writes sources.toml the way treefmt formats it
  ];
}
