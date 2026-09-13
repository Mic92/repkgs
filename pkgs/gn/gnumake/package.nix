{ package }:
package {
  name = "gnumake";
  uses = [ "autotools" ];
  bootstrapTools = true;
  # `include`/-l search and locale dir named the install prefix
  patches = [ ./relocatable.patch ];
  autotools.flags = [ "--without-guile" ];
  autotools.makeFlags = [ "MAKEINFO=true" ];
  tests.relocated = true;
  tests.run = false; # perl
  bin = [ "make" ];
}
