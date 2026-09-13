{
  package,
}:
package {
  name = "blake3";
  uses = [ "cmake" ];
  cmake.root = "c";
  cmake.defs = {
    BLAKE3_USE_TBB = false;
  };
}
