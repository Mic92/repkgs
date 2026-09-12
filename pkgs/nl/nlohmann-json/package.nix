# header-only. `default` is the single json.hpp the bootstrap compiles jig with, `tree` the
# release with the cmake package
{
  package,
  sources,
  buildPkgs,
}:
package {
  name = "nlohmann-json";
  source = sources.fetch "tree";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links cppdap, which wants this
  cmake.defs = {
    JSON_BuildTests = false;
    JSON_MultipleHeaders = true;
  };
}
