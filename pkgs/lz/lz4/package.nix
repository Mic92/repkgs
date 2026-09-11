{
  package,
  buildPkgs,
}:
package {
  name = "lz4";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.root = "build/cmake";
}
