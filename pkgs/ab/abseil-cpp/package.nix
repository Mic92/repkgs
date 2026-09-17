{
  package,
  pkgs,
  sources,
}:
package {
  name = "abseil-cpp";
  uses = [ "cmake" ];
  cmake.defs = {
    CMAKE_CXX_STANDARD = "17";
    ABSL_PROPAGATE_CXX_STD = true;
    ABSL_BUILD_TESTING = true;
    ABSL_USE_EXTERNAL_GOOGLETEST = true;
  };
  # time_test loads named zones. The bazel build points TZDIR at the bundled copy, cmake does not
  env.TZDIR = "${sources.fetch "default"}/absl/time/internal/cctz/testdata/zoneinfo";
  dependencies = [ pkgs.googletest ];
}
