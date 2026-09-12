{ package }:
package {
  name = "c-ares";
  uses = [ "cmake" ];
  cmake.defs = {
    CARES_BUILD_TOOLS = false;
  };
}
