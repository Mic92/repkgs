{ package }:
package {
  name = "inih";
  uses = [ "meson" ];
  meson.defs = {
    with_INIReader = true;
  };
}
