{
  package,
  pkgs,
}:
package {
  name = "pixman";
  uses = [ "meson" ];
  meson.defs = {
    libpng = "enabled";
    tests = "enabled";
  };
  tests.skip = [
    "stress-test"
    "tolerance-test"
    "composite"
  ]; # minutes each; time out on a loaded builder
  tests.separate = true;
  dependencies = [ pkgs.libpng ];
}
