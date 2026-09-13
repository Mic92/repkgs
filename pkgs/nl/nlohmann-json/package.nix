{ package }:
package {
  name = "nlohmann-json";
  uses = [ "cmake" ];
  cmake.defs = {
    JSON_BuildTests = false;
    JSON_MultipleHeaders = true;
  };
  # header-only: cmake configure generates pkg-config and cmake targets;
  # no binaries to build or test.
  phases.remove = [
    "cmake.build"
    "cmake.test"
  ];
}
