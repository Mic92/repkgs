{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "libarchive";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap;
  cmake.defs = {
    ENABLE_OPENSSL = false;
    ENABLE_LIBXML2 = false;
    ENABLE_EXPAT = true;
    ENABLE_ACL = false;
    ENABLE_XATTR = false;
    ENABLE_TEST = false;
  };
  dependencies = [
    pkgs.zlib
    pkgs.bzip2
    pkgs.xz
    pkgs.zstd
    pkgs.lz4
    pkgs.expat
  ];
  tests.run = false; # ENABLE_TEST: 30 min, several want a real tty/locale
  bin = [
    "bsdtar"
    "bsdcpio"
    "bsdunzip"
  ];
}
