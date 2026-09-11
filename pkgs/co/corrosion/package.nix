{ package, buildPkgs }:
package {
  name = "corrosion";
  uses = [ "cmake" ];
  # configure checks that cargo and rustc exist
  buildDependencies = [ buildPkgs.rust ];
  phases.remove = [ "cmake.test" ]; # its tests build dozens of crates from the network
  cmake.defs = {
    CORROSION_BUILD_TESTS = false;
  };
}
