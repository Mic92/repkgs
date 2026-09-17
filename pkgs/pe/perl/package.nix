{
  package,
  pkgs,
  sources,
  platform,
  toolchain,
}:
package {
  # perl-cross has no win32 configuration
  platforms.posix = true;
  name = "perl";
  dependencies = [ pkgs.zlib ];
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.outOfTree = false;
  phases.replace."autotools.configure" = "perl.configure";
  phases.after."autotools.install" = "perl.scrub";
  env =
    if platform.cross then
      {
        PERL_CROSS = "${sources.fetch "cross"}";
        PERL_CROSS_PATCH = "${./upstream-cross-darwin.patch}";
        PERL_SYSROOT = "${toolchain.sysroot}";
        # under perl-cross MakeMaker's fixin sees "env perl", not "perl", and resolves env on PATH
        PERL_MM_SHEBANG = "relocatable";
      }
    else
      { };
  tests.run = false; # hours; t/ wants a hostname, /etc/protocols, ...
}
