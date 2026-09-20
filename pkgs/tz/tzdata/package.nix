# share/zoneinfo plus zic, zdump and tzselect (tzcode and tzdata are one tree, tzdb)
{
  package,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "tzdata";
  # zic and friends are POSIX programs, Windows keeps its own zone database
  platforms.os = [
    "linux"
    "macos"
  ];
  uses = [ "make" ];
  # TOPDIR is / for the compiled-in TZDIR and TZDEFAULT (the machine's), the prefix only at install
  make.flags = [
    "cc=cc"
    "AR=llvm-ar"
    "RANLIB=llvm-ranlib"
    "USRDIR="
    "ZICDIR=$(BINDIR)"
  ]
  # cross: the zone files are compiled by a zic that runs here
  ++ on platform.cross [ "zic=${buildPkgs.tzdata}/bin/zic" ];
  make.installFlags = [ "TOPDIR=$(PREFIX)" ];
  make.programs = [
    "zic"
    "zdump"
  ];
  tests.run = false; # `make check` validates the sources against the web and a UTF-8 grep
}
