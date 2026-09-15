{
  package,
  buildPkgs,
}:
package {
  name = "libseccomp";
  uses = [ "autotools" ];
  patches = [ ./upstream-tests-tail-pid.patch ];
  platforms.os = [ "linux" ];
  buildDependencies = [
    buildPkgs.gperf
    buildPkgs.bash # tests/regression
    buildPkgs.which
    buildPkgs.util-linux
  ];
}
