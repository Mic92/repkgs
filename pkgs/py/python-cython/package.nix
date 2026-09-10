{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "python-cython";
  uses = [ "python" ];
  python.module = "Cython";
  dependencies = [ pkgs.cpython ]; # bin/cython runs under it
  buildDependencies = [ buildPkgs.python-setuptools ];
  bin = [ "cython" ];
}
