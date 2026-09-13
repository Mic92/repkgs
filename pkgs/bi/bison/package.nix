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
  # share/bison and locale via reloc.h. gnulib's --enable-relocatable keeps the configured
  # prefix in the binary to compute the new one from
  patches = [ ./relocatable.patch ];
  tests.run = false; # autom4te (perl)
}
