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
  # the tag says add_library(STATIC): a .a whose cmake config wants nlohmann_json found again
  dependencies = [ pkgs.nlohmann-json ];
  exports.propagate = [ pkgs.nlohmann-json ];
}
