{ package }:
package {
  name = "m4";
  uses = [ "autotools" ];
  bootstrapTools = true;
  tests.separate = true; # the suite wants a real awk and diff, m4 is built with the seed only
}
