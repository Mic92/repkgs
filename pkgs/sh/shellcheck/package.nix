{ package }:
package {
  name = "shellcheck";
  uses = [ "cabal" ];
  cabal.exes = [ "shellcheck" ];
  bin = [ "shellcheck" ];
}
