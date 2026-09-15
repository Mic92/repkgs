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
  patches = [ ./relocatable.patch ]; # the magic database relative to libmagic
  # cross: compiling the magic database takes a `file` of the same version
  buildDependencies = on platform.cross [ buildPkgs.file ];
  dependencies = [
    pkgs.zlib
    pkgs.bzip2
    pkgs.xz
    pkgs.zstd
  ];
}
