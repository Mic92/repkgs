# nixbot builds .#checks (nix/ci.nix), .#packages is the whole set. The package set itself is
# default.nix and takes no inputs; nixpkgs is what treefmt and the seed build already use.
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      # aarch64-linux once its seed nar is uploaded (pkgs/se/seed/upload.nu)
      systems = [ "x86_64-linux" ];
      each = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      packages = each (system: import ./default.nix { inherit system; });
      checks = each (system: import ./nix/ci.nix { inherit system nixpkgs; });
      devShells = each (system: {
        default = import ./shell.nix { pkgs = nixpkgs.legacyPackages.${system}; };
      });
    };
}
