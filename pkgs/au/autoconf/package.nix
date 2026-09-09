{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "autoconf";
  uses = [ "autotools" ];
  buildDependencies = [
    buildPkgs.m4
    buildPkgs.perl
  ];
  # autoconf, autom4te… are perl and sh scripts that exec m4
  runtimeDependencies = [
    pkgs.m4
    pkgs.perl
  ];
  tests.relocated = true;
  # 555/557 pass in 20 min. AS_DIRNAME and AC_FUNC_GETGROUPS probe host behaviour (toybox
  # dirname corner cases, no supplementary groups in the sandbox)
  tests.run = false;
}
