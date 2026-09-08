{ package }:
package {
  name = "m4";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
  ];
  tests.relocated = true;
  tests.run = false; # gnulib test-posix_spawn-chdir spins, PLAN follow-ups
  bin = [ "m4" ];
}
