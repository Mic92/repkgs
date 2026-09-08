{ package }:
package {
  name = "python-pyproject-hooks";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "pyproject_hooks";
}
