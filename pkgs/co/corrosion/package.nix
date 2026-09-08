{ package }:
package {
  name = "corrosion";
  uses = [
    "cmake"
    "cargo"
  ];
  steps = [
    "cmake.configure"
    "cmake.build"
    "cmake.install"
  ]; # its tests build dozens of crates from the network
  cmake.defs = {
    CORROSION_BUILD_TESTS = false;
  };
}
