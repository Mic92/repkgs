{ package }:
package {
  name = "python-installer";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "installer";
}
