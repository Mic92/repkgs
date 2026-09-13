# header-only. `default` is the single json.hpp the bootstrap compiles jig with, `tree` the
# release with the cmake package
{
  package,
  buildPkgs,
}:
package {
  name = "nlohmann-json";
  source = "tree";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links cppdap, which wants this
  cmake.defs = {
    JSON_BuildTests = false;
    JSON_MultipleHeaders = true;
  };
}
