{ package }:
package {
  name = "python-flit-core";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "flit_core";
}
