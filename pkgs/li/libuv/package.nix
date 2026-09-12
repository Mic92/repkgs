{
  package,
  buildPkgs,
}:
package {
  name = "libuv";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.defs = {
    LIBUV_BUILD_TESTS = false;
  };
}
