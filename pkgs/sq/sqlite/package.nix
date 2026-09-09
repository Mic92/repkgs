{
  package,
  pkgs,
}:
package {
  name = "sqlite";
  uses = [ "autotools" ];
  autotools.outOfTree = false;
  # what distributions ship and dependents (dbmate) test for
  autotools.flags = [ "--enable-fts5" ];
  tests.run = false; # needs tcl
  dependencies = [ pkgs.zlib ];
}
