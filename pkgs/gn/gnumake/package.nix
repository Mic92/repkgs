{
  package,
  platform,
  buildPkgs,
}:
package {
  name = "gnumake";
  uses = [ "autotools" ];
  bootstrapTools = true;
  # `include`/-l search and locale dir named the install prefix
  patches = [ ./relocatable.patch ];
  autotools.flags = [ "--without-guile" ];
  autotools.makeFlags = [ "MAKEINFO=true" ];
  # src/w32 passes message buffers as format strings
  cc.hardening.format = platform.os != "windows";
  tests.separate = true;
  tests.dependencies = [ buildPkgs.perl ];
  # general4 unsets PATH and expects confstr(_CS_PATH) to hold a shell
  phases.before."autotools.test" = [
    {
      name = "skip-general4";
      run = "rm ($c.src)/tests/scripts/misc/general4";
    }
  ];
  bin = [ "make" ];
}
