{
  package,
  buildPkgs,
}:
package {
  name = "python-trove-classifiers";
  uses = [ "python" ];
  python.module = "trove_classifiers";
  buildDependencies = [ buildPkgs.python-setuptools ];
}
