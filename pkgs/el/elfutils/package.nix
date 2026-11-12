# libelf, libdw and the eu-* tools. perf needs libelf and libdw for symbols and DWARF.
# debuginfod is off: the server wants libmicrohttpd and the client wants curl at runtime, and
# nothing here asks for either.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "elfutils";
  # argp and obstack are glibc's, and the sources use them unconditionally
  platforms.libc = [ "glibc" ];
  uses = [ "autotools" ];
  autotools.flags = [
    "--disable-debuginfod"
    "--disable-libdebuginfod"
    "--disable-nls"
    # every tool still compiles LOCALEDIR in, and an output that names its own install prefix
    # is not relocatable. With nls off nothing reads it, so it goes where the man pages go
    "--localedir=/usr/share/locale"
    "--enable-deterministic-archives"
    # the tree builds with -Werror and clang finds warnings gcc does not
    "--disable-werror"
  ];
  dependencies = [
    pkgs.zlib
    pkgs.bzip2
    pkgs.xz
    pkgs.zstd
  ];
  buildDependencies = [
    buildPkgs.m4
    buildPkgs.bison
    buildPkgs.flex
  ];
  phases.after."autotools.install" = {
    name = "scrub";
    run = ''
      # eu-make-debug-archive is a shell script whose UNSTRIP and AR defaults are
      # $out/bin/eu-*, and no relocatable output may name its own install prefix. The script
      # is the only file left that does, so point it beside itself.
      let f = $"($c.out)/bin/eu-make-debug-archive"
      open --raw $f | str replace -a $"($c.out)/bin/" '$(dirname "$0")/' | save -f $f
    '';
  };
  bin = [ "eu-readelf" ];
  # the suite runs the tools over its own fixtures and takes minutes
  tests.run = false;
  tests.version = "--version";
}
