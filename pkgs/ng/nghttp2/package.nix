{
  package,
  buildPkgs,
}:
package {
  name = "nghttp2";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.defs = {
    ENABLE_LIB_ONLY = true;
    BUILD_TESTING = false;
  };
}
