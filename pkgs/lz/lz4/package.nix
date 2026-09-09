{ package }:
package {
  name = "lz4";
  uses = [ "cmake" ];
  cmake.root = "build/cmake";
}
