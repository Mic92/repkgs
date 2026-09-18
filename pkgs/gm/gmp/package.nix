{ package, buildPkgs }:
package {
  name = "gmp";
  uses = [ "autotools" ];
  patches = [ ./upstream-loongarch-int128.patch ];
  autotools.flags = [
    "--enable-cxx"
    "--with-pic"
  ];
  buildDependencies = [ buildPkgs.m4 ];
}
