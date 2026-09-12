# Upstream's GHC bindist under our dynamic linker: the compiler that builds Haskell packages until
# ghc is built from source (it needs a GHC). Build tool only, taken from buildPkgs by cabal.nu.
# riscv64: upstream has no bindist, Debian's .deb (LLVM backend, links libnuma)
{
  package,
  pkgs,
  buildPkgs,
  platform,
  on,
}:
let
  deb = platform.cpu == "riscv64";
in
package (
  {
    name = "ghc-bootstrap";
    prebuilt = true;
    platforms.cross = false;
    dependencies = [
      pkgs.gmp
      pkgs.ncurses
      pkgs.libffi
    ]
    ++ on deb [
      pkgs.numactl
      pkgs.llvm
    ];
    buildDependencies = on (!deb) [ buildPkgs.cpython ];
    phases = [
      {
        name = "install";
        run =
          if deb then
            ''
              use ghc-bindist.nu
              ghc-bindist install-deb
            ''
          else
            ''
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
  # the .deb's version, not the upstream pin
  // on deb { version = "9.10.3"; }
)
