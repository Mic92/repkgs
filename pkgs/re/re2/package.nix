{ package, pkgs }:
package {
  name = "re2";
  uses = [ "cmake" ];
  cmake.defs.RE2_TEST = true; # RE2_BUILD_TESTING also wants google benchmark
  dependencies = [
    pkgs.abseil-cpp
    pkgs.googletest
  ];
}
