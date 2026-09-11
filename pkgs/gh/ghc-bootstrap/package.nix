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
    pkgs.libgcc-shim # see nix/build-systems.nix cabal.libs
  ];
  buildDependencies = [ buildPkgs.cpython ];
  phases = [
    {
      name = "install";
      run = ''
        # configure runs bin/ghc-toolchain-bin and `make install` the installed ghc-pkg: the
        # bindist must already run here, finish's implant over $out then only adjusts paths
        implant $c $c.src
        # the bindist's configure records cc/ld/ar for ghc's settings file and relinks nothing
        x sh ./configure $"--prefix=($c.out)" CC=cc CXX=c++ LD=ld AR=ar RANLIB=ranlib STRIP=llvm-strip
        x make install
        # the bin/ sh wrappers spell out $out in every variable: derive it from the script's location
        for f in (ls $"($c.out)/bin" | where type == file | get name) {
          open --raw $f
          | str replace '#!/bin/sh' "#!/bin/sh\ntop=$(cd \"''${0%/*}/..\" && pwd)" # builtins only: PATH may be empty
          | str replace -a $c.out '$top'
          | save -f $f
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
