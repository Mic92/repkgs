# `nix-shell` for the Makefile: libc++ clang and nixpkgs' builds of the three libraries (the
# bootstrap compiles them from vendored sources instead).
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell.override { stdenv = pkgs.llvmPackages_23.libcxxStdenv; } {
  packages = [
    pkgs.libblake3
    pkgs.zstd
    pkgs.nlohmann_json
    pkgs.gdb
  ];
  hardeningDisable = [ "all" ];
  # <json.hpp> as the bootstrap lays it out, not <nlohmann/json.hpp>
  NIX_CFLAGS_COMPILE = "-isystem ${pkgs.nlohmann_json}/include/nlohmann";
}
