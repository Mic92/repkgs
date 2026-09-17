{ package, pkgs }:
package {
  name = "libwebp";
  uses = [ "cmake" ];
  # cwebp/dwebp read png, jpeg, gif. tiff would be a cycle (libtiff links libwebp)
  cmake.defs.WEBP_BUILD_EXTRAS = false;
  dependencies = [
    pkgs.libjpeg-turbo
    pkgs.libpng
    pkgs.giflib
  ];
}
