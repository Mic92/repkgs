{ package, pkgs }:
package {
  name = "protobuf";
  uses = [ "cmake" ];
  cmake.defs = {
    protobuf_ABSL_PROVIDER = "package";
    protobuf_BUILD_SHARED_LIBS = true;
    protobuf_USE_EXTERNAL_GTEST = true;
  };
  dependencies = [
    pkgs.googletest
    pkgs.abseil-cpp
    pkgs.zlib
  ];
}
