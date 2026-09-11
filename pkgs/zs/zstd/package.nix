{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "zstd";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap;
  cmake.root = "build/cmake";
  cmake.defs = {
    ZSTD_BUILD_CONTRIB = false;
    ZSTD_LEGACY_SUPPORT = false;
    ZSTD_BUILD_TESTS = false;
  };
  tests.run = false; # 10 min of fuzz tests
  dependencies = [
    pkgs.zlib
    pkgs.xz
    pkgs.lz4
  ];
}
