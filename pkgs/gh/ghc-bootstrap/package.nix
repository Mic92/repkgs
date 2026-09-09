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
  dependencies = [
    pkgs.gmp
    pkgs.ncurses
    pkgs.libffi
  ];
  buildDependencies = [ buildPkgs.cpython ];
  steps = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        # the bindist's configure records cc/ld/ar for ghc's settings file and relinks nothing
        x sh ./configure $"--prefix=($c.out)" CC=cc CXX=c++ LD=ld AR=ar RANLIB=ranlib STRIP=llvm-strip
        x make install
        # the bin/ wrappers hardcode exedir=$out/…: find lib/ from the script's own location instead
        for f in (ls $"($c.out)/bin" | where type == file | get name) {
          open --raw $f | str replace -r 'exedir="[^"]*/lib/' 'exedir="$(cd "$(dirname "$0")" && pwd)/../lib/' | save -f $f
        }
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
