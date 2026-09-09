# GHC -jsem tokens served from pkgs-cache slots (builder/systems/cabal.nu runs cabal under it)
{ package }:
package {
  name = "jsem";
  version = "1";
  source = ./src;
  steps = [
    {
      name = "build";
      run = ''
        # the same default jig has: the daemon socket in the state dir next to the store
        let flags = [-std=c++26 -O2 -Wall -Wextra -Werror -UNDEBUG $"-DJSEM_DEFAULT_SOCK=\"($env.NIX_STORE | path dirname)/var/nix/jigd/socket\"" broker.cc]
        x c++ ...$flags jsem_test.cc -o jsem_test
        x ./jsem_test
        mkdir $"($c.out)/bin"
        x c++ ...$flags main.cc -o $"($c.out)/bin/jsem"
      '';
    }
  ];
  tests.version = false;
}
