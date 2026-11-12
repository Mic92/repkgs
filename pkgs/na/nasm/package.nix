{
  package,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "nasm";
  uses = [ "autotools" ];
  # windows: win/manifest.rc is named relative to the build dir, and win/ is not created there
  autotools.outOfTree = platform.os != "windows";
  buildDependencies = [ buildPkgs.perl ];
  tests.run = false; # no check target, test/ compares against a reference nasm
}
