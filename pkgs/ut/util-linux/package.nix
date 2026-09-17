# libuuid, libblkid, libmount, libsmartcols, libfdisk and the tools
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "util-linux";
  uses = [ "meson" ];
  patches = [ ./relocatable.patch ]; # agetty's vendor issue.d under the prefix
  meson.defs = {
    sysconfdir = "/etc";
    build-python = "disabled";
    # its ~120 build-<tool> switches are feature options too. Libraries stay explicit below
    auto_features = "auto";
    ncursesw = "enabled";
    readline = "enabled";
    zlib = "enabled";
    libutil = "enabled";
    cryptsetup = "disabled";
    build-vipw = "disabled"; # installs a man8/vigr.8 link to a page only asciidoctor would build
  };
  buildDependencies = [
    buildPkgs.bison
    buildPkgs.flex
  ];
  dependencies = [
    pkgs.ncurses
    pkgs.zlib
    pkgs.readline
    pkgs.sqlite
    pkgs.libxcrypt
    pkgs.libcap
  ];
  platforms.os = [ "linux" ];
}
