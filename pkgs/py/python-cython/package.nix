{
  package,
  buildPkgs,
}:
package {
  name = "python-cython";
  uses = [ "python" ];
  python.module = "Cython";
  buildDependencies = [ buildPkgs.python-setuptools ];
  bin = [ "cython" ];
}
