{ package, pkgs }:
package {
  name = "libtiff";
  uses = [ "cmake" ];
  cmake.defs = {
    tiff-docs = false;
    lerc = false;
    jbig = false;
  };
  dependencies = [
    pkgs.zlib
    pkgs.xz
    pkgs.zstd
    pkgs.libjpeg-turbo
    pkgs.libwebp
  ];
}
