{ package }:
package {
  name = "numactl";
  platforms.os = [ "linux" ];
  uses = [ "autotools" ];
  tests.run = false; # test/ wants a NUMA machine
}
