{
  package,
  platform,
  on,
}:
package {
  name = "libcpuid";
  # cmake sets MSVC only for cl-style drivers, the project keys windows specifics on it
  platforms.abi = [
    "gnu"
    "apple"
  ];
  uses = [ "cmake" ];
  cmake.defs = {
    # the ARM kernel driver installs DKMS sources to /usr/src
    LIBCPUID_BUILD_DRIVERS = false;
  }
  # it includes GNUInstallDirs only if(UNIX), the install rules use its variables regardless
  // on (platform.os == "windows") {
    CMAKE_INSTALL_BINDIR = "bin";
    CMAKE_INSTALL_LIBDIR = "lib";
    CMAKE_INSTALL_INCLUDEDIR = "include";
  };
}
