# pandoc-cli from hackage: the executable package, pandoc the library comes from the version set
{ package, pkgs }:
package {
  name = "pandoc";
  uses = [ "cabal" ];
  cabal.exes = [ "pandoc" ];
  dependencies = [ pkgs.zlib ];
  bin = [ "pandoc" ];
}
