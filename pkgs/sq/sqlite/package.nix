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
  # upstream leaves the soname to the packager (main.mk LDFLAGS.libsqlite3.soname);
  # without one every DT_NEEDED naming libsqlite3.so keeps its absolute build-time path
  make.flags = on (platform.os == "linux") [
    "LDFLAGS.libsqlite3.soname=-Wl,-soname,libsqlite3.so.0"
  ];
  tests.run = false; # needs tcl
  dependencies = [ pkgs.zlib ];
}
