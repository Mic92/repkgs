{ package, buildPkgs }:
package {
  name = "libjpeg-turbo";
  uses = [ "cmake" ];
  cmake.defs.WITH_JPEG8 = true;
  buildDependencies = [ buildPkgs.nasm ];
  # -shared and -static bit tests write the same testout* files in one directory
  tests.parallel = false;
}
