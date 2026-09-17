{
  package,
  buildPkgs,
}:
package {
  name = "diffutils";
  uses = [ "autotools" ];
  bootstrapTools = true;
  patches = [ ./upstream-strptime-prototypes.patch ];
  # man/ regenerates *.1 with help2man (perl)
  autotools.makeFlags = [ "SUBDIRS=lib src" ];
  tests.separate = true;
  tests.dependencies = [ buildPkgs.perl ];
  bin = [
    "diff"
    "cmp"
  ];
}
