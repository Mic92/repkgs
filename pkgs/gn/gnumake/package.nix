{ package }:
package {
  name = "gnumake";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [ "--without-guile" ];
  autotools.makeFlags = [ "MAKEINFO=true" ];
  tests.relocated = true;
  tests.run = false; # perl
  bin = [ "make" ];
}
