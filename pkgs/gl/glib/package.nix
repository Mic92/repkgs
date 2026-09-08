# GLib for qemu: no introspection, docs, nls, sysprof, selinux, libmount
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "glib";
  uses = [ "meson" ];
  meson.options = {
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
  };
  dependencies = [
    pkgs.pcre2
    pkgs.libffi
    pkgs.zlib
  ];
  # meson.build and the codegen tools run python3 with `packaging`
  buildDependencies = [
    buildPkgs.cpython
    buildPkgs.python-packaging
  ];
  runtimeDependencies = [ buildPkgs.cpython ]; # glib-mkenums, gdbus-codegen
  tests.run = false;
  bin = [
    "glib-compile-resources"
    "gdbus"
  ];
}
