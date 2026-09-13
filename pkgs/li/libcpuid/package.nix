{
  package,
}:
package {
  name = "libcpuid";
  uses = [ "cmake" ];
  # the ARM kernel driver installs DKMS sources to /usr/src
  cmake.defs.LIBCPUID_BUILD_DRIVERS = false;
}
