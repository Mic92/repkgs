{ package, pkgs }:
package {
  name = "mpfr";
  uses = [ "autotools" ];
  dependencies = [ pkgs.gmp ];
}
