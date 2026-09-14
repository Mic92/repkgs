# GHC from source, booted by ghc-bootstrap. hadrian is a cabal project in hadrian/, ghc.nu runs
# configure, hadrian binary-dist-dir and that bindist's install.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "ghc";
  uses = [ "cabal" ];
  # hadrian (9.6 to 9.12) only makes cross compilers, never a ghc that runs on the target
  platforms.cross = false;
  cabal.root = "hadrian";
  cabal.exes = [ "hadrian" ];
  # our hackage snapshot has no index states, selftest wants an old QuickCheck
  cabal.flags = [
    "--index-state=HEAD"
    "--flags=-selftest"
  ];
  # hadrian ran `bash autoreconf`, ours is a launcher binary
  patches = [ ./upstream-hadrian-autoreconf-exec.patch ];
  phases.replace."cabal.install" = [
    "ghc.configure"
    "ghc.build"
    "ghc.install"
  ];
  phases.remove = [ "cabal.test" ];
  dependencies = [
    pkgs.gmp
    pkgs.ncurses
    pkgs.libffi
  ];
  buildDependencies = [
    buildPkgs.cpython
    buildPkgs.autoconf
  ];
  bin = [
    "ghc"
    "ghc-pkg"
    "runghc"
    "hsc2hs"
    "haddock"
  ];
  tests.version = "--numeric-version";
  exports = false;
}
