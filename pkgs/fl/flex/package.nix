{
  package,
  pkgs,
}:
package {
  name = "flex";
  uses = [ "autotools" ];
  bootstrapTools = true;
  buildDependencies = [ pkgs.m4 ];
  runtimeDependencies = [ pkgs.m4 ];
  autotools.flags = [
    "ac_cv_path_M4=${pkgs.m4}/bin/m4"
    # skip the stage1flex bootstrap dance, scan.c ships in the tarball
    "--disable-bootstrap"
  ];
  tests.run = false; # bison + full autotools
}
