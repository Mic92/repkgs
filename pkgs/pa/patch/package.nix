{ package }:
package {
  name = "patch";
  uses = [ "autotools" ];
  bootstrapTools = true;
  tests.run = false; # ed
}
