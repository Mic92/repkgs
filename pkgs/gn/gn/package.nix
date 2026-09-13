# gn has no releases: Debian's snapshot tarball of gn.googlesource.com
{ package, buildPkgs }:
let
  pin = (builtins.fromTOML (builtins.readFile ./sources.toml)).pin;
  rev = builtins.head (builtins.match ".*[.]([0-9a-f]+)" pin.version);
in
package {
  name = "gn";
  buildDependencies = [
    buildPkgs.cpython
    buildPkgs.ninja
  ];
  phases = [
    {
      name = "build";
      run = ''
        cd $c.src
        x python3 build/gen.py --no-last-commit-position --no-strip --no-static-libstdc++ --allow-warnings $"--out-path=($c.build)"
        '#define LAST_COMMIT_POSITION_NUM ${toString pin.position}
        #define LAST_COMMIT_POSITION "${toString pin.position} (${rev})"
        ' | save $"($c.build)/last_commit_position.h"
        x ninja -C $c.build $"-j($c.njobs)" gn
      '';
    }
  ];
  install."bin/gn" = "../build/gn";
  tests.version = false; # prints the commit position, not a version
}
