{ package }:
package {
  name = "giflib";
  uses = [ "make" ];
  patches = [ ./upstream-darwin-install-name.patch ];
  make.flags = [
    "CC=cc"
    # libutil.so only serves the uninstalled helper programs, and on Darwin it does not even link
    "SHARED_LIBS=$(LIBGIFSO)"
  ];
  # the default goal also renders the docs with ImageMagick
  make.buildTarget = [
    "shared-lib"
    "static-lib"
    "gif2rgb"
    "gifbuild"
    "giftool"
    "giftext"
    "gifclrmp"
    "giffix"
  ];
  make.installTarget = [
    "install-bin"
    "install-include"
    "install-lib"
  ];
  tests.run = false; # compares against ImageMagick output
}
