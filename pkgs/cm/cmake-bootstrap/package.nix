# cmake built by its ./bootstrap (make, bundled libraries), for the build machine only: the cmake
# that builds zlib, zstd, expat, curl, libarchive and then cmake proper, which link those
{ package }:
package {
  name = "cmake-bootstrap";
  uses = [ "make" ];
  phases = [
    {
      name = "configure";
      run = ''
        (x $env.CONFIG_SHELL ./bootstrap $"--prefix=($c.out)" $"--parallel=($c.njobs)" --no-system-libs
          --no-qt-gui --docdir=share/doc/cmake --mandir=share/man
          -- -DCMAKE_USE_OPENSSL=OFF -DBUILD_TESTING=OFF -DCMake_BUILD_LTO=OFF $"-DCMAKE_SYSTEM_PREFIX_PATH=($c.platform.sysroot)")
      '';
    }
    "make.build"
    "make.install"
  ];
  platforms.cross = false;
  tests.run = false;
  bin = [
    "cmake"
    "ctest"
    "cpack"
  ];
}
