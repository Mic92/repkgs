{ package }:
package {
  name = "gawk";
  uses = [ "autotools" ];
  bootstrapTools = true;
  # AWKPATH, AWKLIBPATH, locale and awklib helpers relative to the binary
  patches = [ ./relocatable.patch ];
  autotools.flags = [ "--disable-mpfr" ];
  tests.run = false; # locale-dependent, wants a full /usr/share/locale
  bin = [
    "gawk"
    "awk"
  ];
}
