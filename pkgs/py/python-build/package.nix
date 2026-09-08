{
  package,
  pkgs,
}:
package {
  name = "python-build";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "build";
  dependencies = [
    pkgs.python-packaging
    pkgs.python-pyproject-hooks
  ];
}
