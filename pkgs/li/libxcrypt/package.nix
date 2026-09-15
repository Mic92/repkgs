{ package, buildPkgs }:
package {
  name = "libxcrypt";
  uses = [ "autotools" ];
  autotools.flags = [ "--disable-werror" ]; # -Werror with -Wextra on a newer clang than upstream tests
  buildDependencies = [ buildPkgs.perl ];
}
