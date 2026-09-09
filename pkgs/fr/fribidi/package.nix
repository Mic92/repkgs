{
  package,
  buildPkgs,
}:
package {
  name = "fribidi";
  uses = [ "meson" ];
  meson.defs = {
    docs = false;
  };
  buildDependencies = [ buildPkgs.cpython ]; # test runner
}
