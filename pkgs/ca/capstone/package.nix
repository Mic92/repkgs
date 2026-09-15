{ package }:
package {
  name = "capstone";
  uses = [ "cmake" ];
  cmake.defs.CAPSTONE_BUILD_MACOS_THIN = true; # else it builds x86_64+arm64 universal and wants lipo
}
