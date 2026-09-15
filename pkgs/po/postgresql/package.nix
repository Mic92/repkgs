{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "postgresql";
  uses = [ "meson" ];
  meson.defs = {
    ssl = "openssl";
    zlib = "enabled";
    readline = "enabled";
    icu = "enabled";
    uuid = "e2fs";
    rpath = false;
    # the machine's zoneinfo, as libc reads it (tzdir-etc-zoneinfo.patch adds NixOS's place).
    # The bundled copy would age with the package and needs a zic that cross cannot run
    system_tzdata = "/usr/share/zoneinfo";
  };
  patches = [ ./tzdir-etc-zoneinfo.patch ];
  buildDependencies = [
    buildPkgs.bison
    buildPkgs.flex
    buildPkgs.perl
  ];
  dependencies = [
    pkgs.openssl
    pkgs.zlib
    pkgs.readline
    pkgs.icu
    pkgs.util-linux
  ];
  # The compiled-in directories are only fallbacks: PostgreSQL derives every
  # path from the running executable (port/path.c make_relative_path). A
  # constant prefix keeps the layout it compares against and drops the store
  # path literal.
  phases.before."meson.configure" = [
    {
      name = "constant-paths";
      run = "edit $\"($c.src)/src/include/meson.build\" { str replace --all \", dir_prefix / dir_\" \", '/usr' / dir_\" }";
    }
  ];
  # Under PGXS every directory comes from pg_config, prefix itself is only exec_prefix's default.
  # The build's tools (bison, perl, llvm-ar, …) are recorded by store path: as bare names an
  # extension build finds its own on PATH
  phases.after."meson.install" = [
    {
      name = "pgxs-prefix";
      run = ''
        edit $"($c.out)/lib/postgresql/pgxs/src/Makefile.global" {
          str replace $"prefix := ($c.out)" 'prefix := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../../../..)'
          | tools-by-name
        }
      '';
    }
  ];
  tests.run = false; # initdb refuses uid 0 in the sandbox
}
