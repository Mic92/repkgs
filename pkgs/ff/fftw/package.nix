# double precision. Single and long double are separate builds of the same tree
{ package, buildPkgs }:
package {
  name = "fftw";
  uses = [ "autotools" ];
  autotools.flags = [
    "--enable-threads"
    # AX_CC_MAXOPT adds -mtune=native when CFLAGS is unset: the output would depend on the builder
    "CFLAGS=-O3 -fomit-frame-pointer -fstrict-aliasing"
  ];
  buildDependencies = [ buildPkgs.perl ]; # tests/check.pl
}
