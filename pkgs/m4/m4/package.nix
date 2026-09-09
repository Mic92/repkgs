{ package }:
package {
  name = "m4";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
  ];
  tests.relocated = true;
  tests.run = false; # gnulib test-float-h.c wants C23 *_IS_IEC_60559 from clang's <float.h>
  bin = [ "m4" ];
}
