# cmake built by its ./bootstrap (make, bundled libraries), for the build machine only: the cmake
# that builds zlib, zstd, expat, curl, libarchive and then cmake proper, which link those
{ package, toolchain }:
package {
  name = "cmake-bootstrap";
  uses = [ "make" ];
  make.configureScript = "bootstrap";
  make.configureFlags = [
    "--no-system-libs"
    "--no-qt-gui"
    "--docdir=share/doc/cmake"
    "--mandir=share/man"
    "--"
    "-DCMAKE_USE_OPENSSL=OFF"
    "-DBUILD_TESTING=OFF"
    "-DCMake_BUILD_LTO=OFF"
    "-DCMAKE_SYSTEM_PREFIX_PATH=${toolchain.sysroot}"
  ];
  platforms.cross = false;
  tests.run = false;
  bin = [
    "cmake"
    "ctest"
    "cpack"
  ];
}
