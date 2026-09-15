{ package, buildPkgs }:
package {
  name = "nasm";
  uses = [ "autotools" ];
  buildDependencies = [ buildPkgs.perl ];
  tests.run = false; # no check target, test/ compares against a reference nasm
}
