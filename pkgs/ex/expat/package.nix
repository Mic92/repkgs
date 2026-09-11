{
  package,
  buildPkgs,
}:
package {
  name = "expat";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.defs = {
    EXPAT_BUILD_DOCS = false;
    EXPAT_BUILD_EXAMPLES = false;
  };
}
