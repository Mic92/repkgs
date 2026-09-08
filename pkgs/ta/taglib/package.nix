{
  package,
  pkgs,
}:
package {
  name = "taglib";
  uses = [ "cmake" ];
  cmake.defs = {
    WITH_ZLIB = true;
  };
  tests.run = false; # needs cppunit
  dependencies = [
    pkgs.zlib
    pkgs.utf8cpp
  ];
}
