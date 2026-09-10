{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "bison";
  uses = [ "autotools" ];
  bootstrapTools = true;
  buildDependencies = [ buildPkgs.m4 ];
  dependencies = [ pkgs.m4 ];
  autotools.flags = [ "M4=${pkgs.m4}/bin/m4" ];
  # relocatable: finds share/bison relative to the binary
  autotools.makeFlags = [ "RELOCATABLE=yes" ];
  tests.run = false; # autom4te (perl)
}
