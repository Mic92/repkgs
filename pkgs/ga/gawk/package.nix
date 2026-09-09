{ package }:
package {
  name = "gawk";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [ "--disable-mpfr" ];
  tests.run = false; # locale-dependent, wants a full /usr/share/locale
  bin = [
    "gawk"
    "awk"
  ];
}
