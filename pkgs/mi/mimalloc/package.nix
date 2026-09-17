{ package }:
package {
  name = "mimalloc";
  uses = [ "cmake" ];
  cmake.defs.MI_INSTALL_TOPLEVEL = true; # lib/ and include/, not lib/mimalloc-x.y/
}
