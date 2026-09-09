# Upstream's cabal-install binary under our dynamic linker, build tool of the cabal build system.
{
  package,
  pkgs,
}:
package {
  name = "cabal-bootstrap";
  prebuilt = true;
  dependencies = [
    pkgs.gmp
    pkgs.zlib
  ];
  install."bin/cabal" = "cabal";
  bin = [ "cabal" ];
  tests.version = "--numeric-version";
}
