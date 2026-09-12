{ package }:
package {
  name = "test-cabal";
  version = "0.1.0.0";
  source = ./src;
  uses = [ "cabal" ];
  cabal.exes = [ "test-cabal" ];
  tests.version = "test-cabal";
}
