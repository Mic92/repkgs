{ package }:
package {
  name = "lz4";
  uses = [ "cmake" ];
  cmake.sourceDir = "build/cmake";
}
