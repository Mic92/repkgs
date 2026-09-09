# CRuby. Cross: configure runs a `baseruby` on the build machine (buildPkgs.ruby); ext/ compile
# through jig like any C. rbconfig.rb records CC etc. as the bare names our cc provides, so gems with
# native extensions build against whatever toolchain is on PATH later (the bundler build system's).
{
  package,
  pkgs,
  buildPkgs,
  platform,
}:
package {
  name = "ruby";
  uses = [ "autotools" ];
  autotools.flags = [
    "--disable-install-doc"
    "--enable-shared"
    "--with-out-ext=win32,win32ole,readline,gdbm,dbm"
    "--without-git"
    "--without-baseruby"
  ]
  ++ (if platform.cross then [ "--with-baseruby=${buildPkgs.ruby}/bin/ruby" ] else [ ]);
  dependencies = [
    pkgs.zlib
    pkgs.openssl
    pkgs.libyaml
    pkgs.libffi
  ];
  tests.run = false; # `make check` is hours; tests.version covers "it starts and finds its stdlib"
  bin = [
    "ruby"
    "gem"
    "bundle"
    "irb"
    "rake"
  ];
}
