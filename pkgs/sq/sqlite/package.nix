{
  package,
  pkgs,
}:
package {
  name = "sqlite";
  uses = [ "autotools" ];
  autotools.outOfTree = false;
  tests.run = false; # needs tcl
  dependencies = [ pkgs.zlib ];
}
