{ package, toolchain }:
package {
  name = "cmake-bootstrap";
  uses = [ "autotools" ];
  # ./bootstrap builds a minimal cmake with make, then cmake configures itself. Its libraries stay
  # bundled because zlib and the rest of the full CMake dependency closure need this tool.
  autotools = {
    configure.script = "bootstrap";
    flags = [
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
  };
  tests.run = false;
  tests.relocated = true;
  bin = [
    "cmake"
    "ctest"
    "cpack"
  ];
}
