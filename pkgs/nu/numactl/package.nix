{ package }:
package {
  name = "numactl";
  uses = [ "autotools" ];
  tests.run = false; # test/ wants a NUMA machine
}
