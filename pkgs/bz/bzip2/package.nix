# plain Makefile. `all` also runs the fresh binary as its test
{
  package,
}:
package {
  name = "bzip2";
  # the Makefile links -lbz2 against libbz2.a, lld-link wants bz2.lib
  platforms.abi = [
    "gnu"
    "apple"
  ];
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
  make.programs = [
    "bzip2"
    "bzip2recover"
  ];
}
