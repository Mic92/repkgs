{ package, platform }:
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
  tests.run = false; # perl
  bin = [ "make" ];
}
