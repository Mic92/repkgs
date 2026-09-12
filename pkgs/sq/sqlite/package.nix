{
  package,
  pkgs,
}:
package {
  name = "sqlite";
  uses = [ "make" ]; # autosetup, not autoconf
  # what distributions ship and dependents test for (dbmate: fts5, nodejs: session, column-metadata)
  make.configureFlags = [
    "--enable-all"
    "--enable-column-metadata"
  ];
  tests.run = false; # needs tcl
  dependencies = [ pkgs.zlib ];
}
