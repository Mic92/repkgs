{ package }:
package {
  name = "inih";
  uses = [ "meson" ];
  meson.options = {
    with_INIReader = true;
  };
}
