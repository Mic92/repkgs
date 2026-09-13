{
  package,
  buildPkgs,
}:
package {
  name = "libseccomp";
  uses = [ "autotools" ];
  platforms.os = [ "linux" ];
  buildDependencies = [
    buildPkgs.gperf
  ];
  tests.run = false; # test scripts assume /bin/bash and require util-linux/which
}
