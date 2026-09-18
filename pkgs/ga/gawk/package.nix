{ package }:
package {
  # langinfo.h, wait
  platforms.posix = true;
  name = "gawk";
  uses = [ "autotools" ];
  bootstrapTools = true;
  # AWKPATH, AWKLIBPATH, locale and awklib helpers relative to the binary
  patches = [
    ./relocatable.patch
    # 5.4.1 without MPFR: unassigned array elements compare != "" (breaks libpng's checksym.awk)
    ./upstream-node-struct-without-mpfr.patch
  ];
  autotools.flags = [ "--disable-mpfr" ];
  tests.run = false; # locale-dependent, wants a full /usr/share/locale
  bin = [
    "gawk"
    "awk"
  ];
}
