{
  package,
  platform,
  buildPkgs,
  on,
}:
package {
  name = "zlib";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.defs = {
    ZLIB_BUILD_EXAMPLES = false;
  };
  tests.parallel = false; # its cmake-integration tests race each other
  # coverage-summary wants gcov. The cmake-integration tests spawn a fresh native cmake+run
  cmake.skipTests = [
    "coverage"
  ]
  ++ on platform.cross [
    "add_subdirectory"
    "find_package"
  ];
}
