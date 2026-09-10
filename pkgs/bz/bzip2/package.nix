{ package }:
package {
  name = "bzip2";
  uses = [ "autotools" ];
  phases = [
    "autotools.build"
    "autotools.install"
  ]; # plain Makefile
  autotools.outOfTree = false;
  autotools.buildTarget = [
    "libbz2.a"
    "bzip2"
    "bzip2recover"
  ]; # `all` also runs the fresh binary as its test
  autotools.makeFlags = [
    "CC=cc"
    "AR=llvm-ar"
    "RANLIB=llvm-ranlib"
    "CFLAGS=-O2 -fPIC"
  ];
}
