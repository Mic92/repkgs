{
  package,
  lib,
  platform,
}:
let
  windows = platform.os == "windows";
in
package {
  name = "giflib";
  uses = [ "make" ];
  patches = [ ./upstream-darwin-install-name.patch ];
  make.flags = [
    "CC=cc"
    # libutil.so only serves the uninstalled helper programs, and on Darwin it does not even link
    "SHARED_LIBS=$(LIBGIFSO)"
  ];
  # the default goal also renders the docs with ImageMagick.
  # Only Darwin gets its own recipe for $(LIBGIFSO); everything else links the ELF way, with
  # -Wl,-soname, which lld rejects for COFF. Nothing imports a gif DLL, so leave it unbuilt
  make.buildTarget = lib.on (!windows) [ "shared-lib" ] ++ [
    "static-lib"
    "gif2rgb"
    "gifbuild"
    "giftool"
    "giftext"
    "gifclrmp"
    "giffix"
  ];
  # cc writes gifbuild.exe on windows, install-bin copies `gifbuild`: these are its INSTALLABLE
  make.programs = [
    "gifbuild"
    "giffix"
    "giftext"
    "giftool"
    "gifclrmp"
  ];
  make.installTarget = [
    "install-bin"
    "install-include"
    # install-lib is static + shared
    (if windows then "install-static-lib" else "install-lib")
  ];
  tests.run = false; # compares against ImageMagick output
}
