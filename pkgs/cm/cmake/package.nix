{
  variant,
  pkgs,
  buildPkgs,
  platform,
}:
variant pkgs.cmake-bootstrap {
  uses.set = [ "cmake" ];
  autotools.remove = true;
  cmake.set = {
    tool = buildPkgs.cmake-bootstrap;
    defs =
      if platform.libc == "msvc" then
        {
          # The system-library closure contains Autotools packages, which do not support MSVC.
          CMAKE_USE_OPENSSL = false;
          CMAKE_USE_SYSTEM_LIBRARIES = false;
        }
      else
        {
          CMake_BUILD_LTO = true;
          CMAKE_USE_SYSTEM_LIBRARY_BZIP2 = true;
          CMAKE_USE_SYSTEM_LIBRARY_CURL = true;
          CMAKE_USE_SYSTEM_LIBRARY_EXPAT = true;
          CMAKE_USE_SYSTEM_LIBRARY_LIBARCHIVE = true;
          CMAKE_USE_SYSTEM_LIBRARY_LIBLZMA = true;
          CMAKE_USE_SYSTEM_LIBRARY_ZLIB = true;
          CMAKE_USE_SYSTEM_LIBRARY_ZSTD = true;
          # TODO: These are not packaged yet and remain bundled.
          CMAKE_USE_SYSTEM_LIBRARY_CPPDAP = false;
          CMAKE_USE_SYSTEM_LIBRARY_FORM = false;
          CMAKE_USE_SYSTEM_LIBRARY_JSONCPP = false;
          CMAKE_USE_SYSTEM_LIBRARY_LIBRHASH = false;
          CMAKE_USE_SYSTEM_LIBRARY_LIBUV = false;
          CMAKE_USE_SYSTEM_LIBRARY_NGHTTP2 = false;
        };
  };
  dependencies.set =
    if platform.libc == "msvc" then
      [ ]
    else
      [
        pkgs.bzip2
        pkgs.curl
        pkgs.expat
        pkgs.libarchive
        pkgs.xz
        pkgs.zlib
        pkgs.zstd
      ];
}
