{ package, buildPkgs }:
package {
  name = "xz";
  # cmake sets MSVC only for cl-style drivers, the project keys windows specifics on it (docs/plan.md)
  platforms.os = [
    "linux"
    "macos"
  ];
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  patches = [ ./upstream-msvc-abi.patch ];
  cmake.flags = [
    "-DBUILD_SHARED_LIBS=ON"
    "-DXZ_NLS=OFF"
    "-DXZ_DOC=OFF"
    "-DXZ_POSIX_SHELL=/bin/sh" # else the build machine's sh gets baked into xzgrep & co
  ];
}
