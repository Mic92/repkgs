{ package, platform }:
package {
  name = "lmdb";
  uses = [ "make" ];
  make.root = "libraries/liblmdb";
  make.flags = [
    "CC=cc"
    "AR=llvm-ar"
    "SOEXT=${platform.ext.shared}"
  ];
  # `make install` copies them by their suffix-less name
  make.programs = [
    "mdb_stat"
    "mdb_copy"
    "mdb_dump"
    "mdb_load"
  ];
  make.testTarget = [ "test" ];
}
