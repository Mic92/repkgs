{
  package,
  platform,
  on,
}:
package {
  name = "libffi";
  uses = [ "autotools" ];
  # decided from `ld --help`, which lists ELF options whatever lld targets
  autotools.flags = on (platform.binfmt != "elf") [ "--disable-symvers" ];
}
