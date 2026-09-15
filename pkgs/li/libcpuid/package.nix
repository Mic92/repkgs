{
  package,
}:
package {
  name = "libcpuid";
  # cmake sets MSVC only for cl-style drivers, the project keys windows specifics on it
  platforms.abi = [
    "gnu"
    "apple"
  ];
  uses = [ "cmake" ];
  # the ARM kernel driver installs DKMS sources to /usr/src
  cmake.defs.LIBCPUID_BUILD_DRIVERS = false;
}
