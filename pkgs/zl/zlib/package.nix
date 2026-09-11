{
  package,
  platform,
  buildPkgs,
}:
package {
  name = "zlib";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap;
  cmake.defs = {
    ZLIB_BUILD_EXAMPLES = false;
  };
  tests.parallel = false; # its cmake-integration tests race each other
  # coverage-summary wants gcov. The cmake-integration tests spawn a fresh native cmake+run
  cmake.skipTests = [
    "coverage"
  ]
  ++ (
    if platform.cross then
      [
        "add_subdirectory"
        "find_package"
      ]
    else
      [ ]
  );
}
