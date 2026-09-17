{ package, pkgs }:
package {
  name = "snappy";
  uses = [ "cmake" ];
  cmake.defs.SNAPPY_BUILD_BENCHMARKS = false; # wants google/benchmark
  patches = [ ./system-gtest.patch ]; # upstream only knows the bundled submodule
  dependencies = [ pkgs.googletest ];
}
