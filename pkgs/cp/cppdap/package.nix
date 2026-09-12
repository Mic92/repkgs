{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "cppdap";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.defs = {
    CPPDAP_USE_EXTERNAL_NLOHMANN_JSON_PACKAGE = true;
  };
  dependencies = [ pkgs.nlohmann-json ];
}
