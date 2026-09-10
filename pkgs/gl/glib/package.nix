# GLib for qemu: no introspection, docs, nls, sysprof, selinux, libmount
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "glib";
  uses = [ "meson" ];
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
  # glib-2.0.pc Requires.private libpcre2-8, libffi, zlib: pkgconf wants them for --cflags too
  exports.propagate = [
    pkgs.pcre2
    pkgs.libffi
    pkgs.zlib
  ];
  bin = [
    "glib-compile-resources"
    "gdbus"
  ];
}
