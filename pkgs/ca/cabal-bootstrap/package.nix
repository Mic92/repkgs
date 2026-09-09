# Upstream's cabal-install binary under our dynamic linker, build tool of the cabal build system.
{
  package,
  pkgs,
  platform,
  sources,
}:
package {
  name = "cabal-bootstrap";
  source = sources.fetch platform.cpu;
  prebuilt = true;
  dependencies = [
    pkgs.gmp
    pkgs.zlib
  ];
  steps = [
    {
      name = "install";
      run = ''
        mkdir $"((ctx).out)/bin"
        cp cabal $"((ctx).out)/bin/cabal"
      '';
    }
  ];
  bin = [ "cabal" ];
  tests.version = "--numeric-version";
}
