{ package, buildPkgs }:
package {
  name = "gmp";
  uses = [ "autotools" ];
  autotools.flags = [
    "--enable-cxx"
    "--with-pic"
  ];
  buildDependencies = [ buildPkgs.m4 ];
}
