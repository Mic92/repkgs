{ package, buildPkgs }:
package {
  name = "libevdev";
  uses = [ "meson" ];
  meson.defs = {
    documentation = "disabled"; # doxygen
    tests = "disabled"; # libcheck
  };
  buildDependencies = [ buildPkgs.cpython ];
  platforms.os = [ "linux" ];
}
