{ package }:
package {
  name = "xxhash";
  uses = [ "cmake" ];
  cmake.root = "cmake_unofficial"; # the Makefile only knows ELF and Mach-O
}
