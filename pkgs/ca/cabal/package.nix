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
  tests.run = false; # the suites need Cabal-described, in cabal's repo but not on hackage
  tests.version = "--numeric-version";
}
