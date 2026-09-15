{
  package,
  buildPkgs,
}:
package {
  name = "jsoncpp";
  # cmake sets MSVC only for cl-style drivers, the project keys windows specifics on it
  platforms.abi = [
    "gnu"
    "apple"
  ];
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.defs = {
    JSONCPP_WITH_TESTS = false;
    JSONCPP_WITH_POST_BUILD_UNITTEST = false;
    BUILD_OBJECT_LIBS = false;
  };
}
