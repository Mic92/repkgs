{
  package,
  pkgs,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "file";
  uses = [ "autotools" ];
  patches = [
    ./relocatable.patch # the magic database relative to libmagic
    ./upstream-mingw-timespec.patch # struct timespec is real on mingw, not winsock's timeval
  ];
  # cross: compiling the magic database takes a `file` of the same version
  buildDependencies = on platform.cross [ buildPkgs.file ];
  # the Makefile would call file.exe here when the target is windows
  autotools.makeFlags = on platform.cross [ "FILE_COMPILE=file" ];
  dependencies = [
    pkgs.zlib
    pkgs.bzip2
    pkgs.xz
    pkgs.zstd
  ]
  ++ on (platform.os == "windows") [ pkgs.tre ]; # mingw has no regex(3)
}
