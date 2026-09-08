{ package }:
package {
  name = "gnumake";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
    "--without-guile"
  ];
  autotools.makeFlags = [ "MAKEINFO=true" ];
  tests.relocated = true;
  tests.run = false; # perl
  bin = [ "make" ];
}
