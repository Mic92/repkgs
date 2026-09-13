# GLib for qemu: no introspection, docs, nls, sysprof, selinux, libmount
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "glib";
  uses = [ "meson" ];
  # charset.alias is the system's
  patches = [ ./relocatable.patch ];
  meson.defs = {
    tests = false;
    nls = "disabled";
    introspection = "disabled";
    sysprof = "disabled";
    selinux = "disabled";
    libmount = "disabled";
    documentation = false;
    man-pages = "disabled";
    dtrace = "disabled";
    systemtap = "disabled";
    wrap_mode = "nodownload";
    localstatedir = "/var";
  };
  dependencies = [
    pkgs.pcre2
    pkgs.libffi
    pkgs.zlib
    pkgs.cpython # glib-mkenums, gdbus-codegen are python scripts
  ];
  # meson.build and the codegen tools run python3 with `packaging`
  buildDependencies = [
    buildPkgs.cpython
    buildPkgs.python-packaging
  ];
  tests.run = false;
  bin = [
    "glib-compile-resources"
    "gdbus"
  ];
}
