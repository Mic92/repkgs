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
    pkgs.cppdap
    pkgs.curl
    pkgs.expat
    pkgs.jsoncpp
    pkgs.libarchive
    pkgs.libuv
    pkgs.ncurses
    pkgs.nghttp2
    pkgs.rhash
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
      CMAKE_USE_SYSTEM_LIBRARY_CPPDAP = has pkgs.cppdap;
      CMAKE_USE_SYSTEM_LIBRARY_CURL = has pkgs.curl;
      CMAKE_USE_SYSTEM_LIBRARY_EXPAT = has pkgs.expat;
      CMAKE_USE_SYSTEM_LIBRARY_FORM = has pkgs.ncurses;
      CMAKE_USE_SYSTEM_LIBRARY_JSONCPP = has pkgs.jsoncpp;
      CMAKE_USE_SYSTEM_LIBRARY_LIBRHASH = has pkgs.rhash;
      CMAKE_USE_SYSTEM_LIBRARY_LIBARCHIVE = has pkgs.libarchive;
      CMAKE_USE_SYSTEM_LIBRARY_LIBLZMA = has pkgs.xz;
      CMAKE_USE_SYSTEM_LIBRARY_LIBUV = has pkgs.libuv;
      CMAKE_USE_SYSTEM_LIBRARY_NGHTTP2 = has pkgs.nghttp2;
      CMAKE_USE_SYSTEM_LIBRARY_ZLIB = has pkgs.zlib;
      CMAKE_USE_SYSTEM_LIBRARY_ZSTD = has pkgs.zstd;
    };
  };
  dependencies.set = system;
}
