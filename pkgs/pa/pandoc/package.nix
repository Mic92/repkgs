# pandoc-cli from hackage: the executable package, pandoc the library comes from the version set
{ package }:
package {
  name = "pandoc";
  uses = [ "cabal" ];
  cabal.exes = [ "pandoc" ];
}
