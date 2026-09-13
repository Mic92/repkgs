{ package }:
package {
  name = "test-cmake";
  version = "1.2";
  source = ./src;
  uses = [ "cmake" ];
  tests.version = "hello";
}
