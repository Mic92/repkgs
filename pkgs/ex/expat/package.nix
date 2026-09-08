{ package }:
package {
  name = "expat";
  uses = [ "cmake" ];
  cmake.defs = {
    EXPAT_BUILD_DOCS = false;
    EXPAT_BUILD_EXAMPLES = false;
  };
}
