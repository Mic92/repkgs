# the nixpkgs the flake locks, for the non-flake entry points (shell.nix, nix/checks.nix,
# pkgs/se/seed/build.nix): their tools and the seed's nu must match what the tree is written for
let
  locked = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.nixpkgs.locked;
in
fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/${locked.rev}.tar.gz";
  sha256 = locked.narHash;
}
