{ package, pkgs }:
package {
  name = "libzip";
  uses = [ "cmake" ];
  dependencies = [
    pkgs.zlib
    pkgs.bzip2
    pkgs.xz
    pkgs.zstd
    pkgs.openssl
  ];
}
