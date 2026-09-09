{
  package,
  buildPkgs,
}:
package {
  name = "fribidi";
  uses = [ "meson" ];
  meson.options = {
    docs = false;
  };
  buildDependencies = [ buildPkgs.cpython ]; # test runner
}
