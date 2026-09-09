{
  package,
  buildPkgs,
}:
package {
  name = "python-pluggy";
  uses = [ "python" ];
  python.module = "pluggy";
  buildDependencies = [
    buildPkgs.python-setuptools
    buildPkgs.python-setuptools-scm
  ];
}
