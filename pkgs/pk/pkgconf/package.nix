# pkg-config implementation without the glib dependency. Installs the pkg-config name too.
{ package }:
package {
  name = "pkgconf";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    # no built-in search path: core.nu sets PKG_CONFIG_PATH from dependencies
    "--with-pkg-config-dir="
    "--with-personality-dir="
    "--with-system-libdir=/nonexistent"
    "--with-system-includedir=/nonexistent"
  ];
  tests.run = false; # kyua
  links."bin/pkg-config" = "pkgconf";
  bin = [
    "pkgconf"
    "pkg-config"
  ];
}
