{
  package,
  pkgs,
  sources,
  platform,
  toolchain,
}:
package {
  name = "perl";
  dependencies = [ pkgs.zlib ];
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.outOfTree = false;
  phases = [
    "perl.configure"
    "autotools.build"
    "autotools.test"
    "autotools.install"
    "perl.scrub"
  ];
  env =
    if platform.cross then
      {
        PERL_CROSS = "${sources.fetch "cross"}";
        PERL_SYSROOT = "${toolchain.sysroot}";
      }
    else
      { };
  tests.run = false; # hours; t/ wants a hostname, /etc/protocols, ...
  tests.relocated = true;
}
