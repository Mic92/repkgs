{
  package,
  pkgs,
  platform,
  on,
}:
package {
  name = "libxml2";
  uses = [ "autotools" ];
  autotools.flags = [ "--sysconfdir=/etc" ]; # the machine's XML/SGML catalogs
  dependencies = [
    pkgs.zlib
    pkgs.xz
  ]
  ++ on (platform.os == "windows") [ pkgs.libiconv ];
}
