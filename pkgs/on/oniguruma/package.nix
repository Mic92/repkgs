{ package }:
package {
  name = "oniguruma";
  uses = [ "autotools" ];
  autotools.configureScript = "configure";
}
