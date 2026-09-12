{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "test-python";
  version = "0.3";
  source = ./src;
  uses = [ "python" ];
  buildDependencies = [ buildPkgs.python-setuptools ];
  dependencies = [ pkgs.cpython ];
  python.module = "tpy";
  tests.version = "tpy-hello";
}
