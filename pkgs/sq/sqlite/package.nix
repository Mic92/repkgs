{
  package,
  pkgs,
  platform,
  on,
}:
package {
  name = "sqlite";
  uses = [ "make" ]; # autosetup, not autoconf
  # what distributions ship and dependents test for (dbmate: fts5, nodejs: session, column-metadata)
  make.configureFlags = [
    "--enable-all"
    "--enable-column-metadata"
  ]
  # autosetup takes the shared library suffix from --host, else from the build machine
  ++ on platform.cross [ "--host=${platform.gnuTriple}" ];
  tests.run = false; # needs tcl
  dependencies = [ pkgs.zlib ];
}
