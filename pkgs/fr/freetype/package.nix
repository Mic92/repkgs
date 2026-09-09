{
  package,
  pkgs,
}:
package {
  name = "freetype";
  uses = [ "meson" ];
  meson.options = {
    zlib = "system";
    png = "enabled";
    bzip2 = "enabled";
    harfbuzz = "disabled";
    brotli = "disabled";
  };
  dependencies = [
    pkgs.zlib
    pkgs.libpng
    pkgs.bzip2
  ];
}
