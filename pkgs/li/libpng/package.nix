{
  package,
  pkgs,
}:
package {
  name = "libpng";
  uses = [ "cmake" ];
  # upstreamable: generated under NOT WIN32, installed under NOT CMAKE_HOST_WIN32
  patches = [ ./cmake-install-pc-when-generated.patch ];
  cmake.defs = {
    PNG_STATIC = false;
    PNG_TOOLS = true;
  };
  dependencies = [ pkgs.zlib ];
  exports.propagate = [ pkgs.zlib ];
}
