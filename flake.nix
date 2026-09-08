# CI entry point only (nixbot builds .#checks, defined in nix/ci.nix). The package set itself is
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
      checks = each (system: import ./nix/ci.nix { inherit system nixpkgs; });
      devShells = each (system: {
        default = import ./shell.nix { pkgs = nixpkgs.legacyPackages.${system}; };
      });
    };
}
