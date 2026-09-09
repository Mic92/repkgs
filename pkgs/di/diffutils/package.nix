{ package }:
package {
  name = "diffutils";
  uses = [ "autotools" ];
  bootstrapTools = true;
  # man/ regenerates *.1 with help2man (perl)
  autotools.makeFlags = [ "SUBDIRS=lib src" ];
  tests.run = false; # perl
  bin = [
    "diff"
    "cmp"
  ];
}
