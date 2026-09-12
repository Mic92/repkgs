# cabal-install from hackage, built by ghc-bootstrap and upstream's cabal binary
{
  package,
  buildPkgs,
}:
package {
  name = "cabal";
  uses = [ "cabal" ];
  cabal.tool = buildPkgs.cabal-bootstrap;
  cabal.exes = [ "cabal" ];
  tests.version = "--numeric-version";
}
