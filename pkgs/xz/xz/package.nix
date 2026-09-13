{ package, buildPkgs }:
package {
  name = "xz";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  patches = [ ./msvc-abi.patch ];
  cmake.flags = [
    "-DBUILD_SHARED_LIBS=ON"
    "-DXZ_NLS=OFF"
    "-DXZ_DOC=OFF"
    "-DXZ_POSIX_SHELL=/bin/sh" # else the build machine's sh gets baked into xzgrep & co
  ];
}
