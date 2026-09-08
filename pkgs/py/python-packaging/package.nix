{ package }:
package {
  name = "python-packaging";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "packaging";
}
