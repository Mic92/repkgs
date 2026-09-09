{ package }:
package {
  name = "m4";
  uses = [ "autotools" ];
  bootstrapTools = true;
  tests.relocated = true;
  tests.run = false; # gnulib test-float-h.c wants C23 *_IS_IEC_60559 from clang's <float.h>
}
