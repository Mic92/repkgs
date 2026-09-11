# cmake proper: configured by cmake-bootstrap, linking the set's libraries where the platform has
# them (bundled otherwise: msvc has no autotools, so no xz, bzip2, curl)
{
  variant,
  pkgs,
  buildPkgs,
}:
let
  system = builtins.filter (p: p.supported) [
    pkgs.bzip2
    pkgs.curl
    pkgs.expat
    pkgs.libarchive
    pkgs.xz
    pkgs.zlib
    pkgs.zstd
  ];
  has = p: p.supported;
in
variant pkgs.cmake-bootstrap {
  name.set = "cmake";
  uses.set = [ "cmake" ];
  autotools.remove = true;
  phases.remove = true;
  platforms.remove = true;
  cmake.set = {
    tool = buildPkgs.cmake-bootstrap;
    defs = {
      BUILD_TESTING = false;
      CMAKE_USE_OPENSSL = false;
      CMAKE_USE_SYSTEM_LIBRARY_BZIP2 = has pkgs.bzip2;
      CMAKE_USE_SYSTEM_LIBRARY_CURL = has pkgs.curl;
      CMAKE_USE_SYSTEM_LIBRARY_EXPAT = has pkgs.expat;
      CMAKE_USE_SYSTEM_LIBRARY_LIBARCHIVE = has pkgs.libarchive;
      CMAKE_USE_SYSTEM_LIBRARY_LIBLZMA = has pkgs.xz;
      CMAKE_USE_SYSTEM_LIBRARY_ZLIB = has pkgs.zlib;
      CMAKE_USE_SYSTEM_LIBRARY_ZSTD = has pkgs.zstd;
      # not packaged: cppdap, form, jsoncpp, librhash, libuv, nghttp2 stay bundled
    };
  };
  dependencies.set = system;
}
