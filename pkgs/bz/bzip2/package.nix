# plain Makefile. `all` also runs the fresh binary as its test
{ package }:
package {
  name = "bzip2";
  uses = [ "make" ];
  make.buildTarget = [
    "libbz2.a"
    "bzip2"
    "bzip2recover"
  ];
  make.flags = [
    "CC=cc"
    "AR=llvm-ar"
    "RANLIB=llvm-ranlib"
    "CFLAGS=-O2 -fPIC"
  ];
  tests.run = false;
}
