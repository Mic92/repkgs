# pkg-config implementation without the glib dependency. Installs the pkg-config name too.
{ package }:
package {
  name = "pkgconf";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    # no built-in search path: core.nu sets PKG_CONFIG_PATH from dependencies
    "--with-pkg-config-dir="
    "--with-system-libdir=/nonexistent"
    "--with-system-includedir=/nonexistent"
  ];
  tests.run = false; # kyua
  steps = [
    "autotools.configure"
    "autotools.build"
    "autotools.install"
    {
      name = "pkg-config-alias";
      run = "^ln -s pkgconf $\"($c.out)/bin/pkg-config\"";
    }
  ];
  bin = [
    "pkgconf"
    "pkg-config"
  ];
}
