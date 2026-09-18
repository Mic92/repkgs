{
  package,
  buildPkgs,
  platform,
}:
package {
  name = "jsoncpp";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.defs = {
    JSONCPP_WITH_TESTS = false;
    JSONCPP_WITH_POST_BUILD_UNITTEST = false;
    BUILD_OBJECT_LIBS = false;
    # import lib and static lib are both lib/jsoncpp.lib there
    BUILD_STATIC_LIBS = platform.libc != "msvc";
  };
}
