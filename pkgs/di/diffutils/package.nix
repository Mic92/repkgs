{ package }:
package {
  name = "diffutils";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
  ];
  # man/ regenerates *.1 with help2man (perl)
  autotools.makeFlags = [ "SUBDIRS=lib src" ];
  tests.run = false; # perl
  bin = [
    "diff"
    "cmp"
  ];
}
