# Upstream's GHC bindist under our dynamic linker: the compiler that builds Haskell packages until
# ghc is built from source (it needs a GHC). Build tool only, taken from buildPkgs by cabal.nu.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "ghc-bootstrap";
  prebuilt = true;
  platforms.cross = false;
  dependencies = [
    pkgs.gmp
    pkgs.ncurses
    pkgs.libffi
  ];
  buildDependencies = [ buildPkgs.cpython ];
  phases = [
    {
      name = "install";
      run = ''
        # configure runs bin/ghc-toolchain-bin and `make install` the installed ghc-pkg: the
        # bindist must already run here, finish's implant over $out then only adjusts paths
        implant $c $c.src
        use ghc-bindist.nu
        ghc-bindist install
      '';
    }
  ];
  bin = [
    "ghc"
    "ghc-pkg"
    "runghc"
  ];
  tests.version = "--numeric-version";
  tests.relocated = true;
  exports = false;
}
