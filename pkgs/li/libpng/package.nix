{
  package,
  pkgs,
}:
package {
  name = "libpng";
  uses = [ "cmake" ];
  cmake.defs = {
    PNG_STATIC = false;
    PNG_TOOLS = true;
  };
  dependencies = [ pkgs.zlib ];
  exports.propagate = [ pkgs.zlib ];
}
