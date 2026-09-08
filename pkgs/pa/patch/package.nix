{ package }:
package {
  name = "patch";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
  ];
  tests.run = false; # ed
  bin = [ "patch" ];
}
