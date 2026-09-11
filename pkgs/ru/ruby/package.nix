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
  ++ (if platform.cross then [ "--with-baseruby=ruby" ] else [ ]);
  buildDependencies = if platform.cross then [ buildPkgs.ruby ] else [ ];
  dependencies = [
    pkgs.bash # rbconfig's CONFIG["SHELL"], mkmf runs commands through it
    pkgs.zlib
    pkgs.openssl
    pkgs.libyaml
    pkgs.libffi
  ];
  phases.after."autotools.install" = [
    {
      # rbconfig.rb describes the build machine: configure's bash and clang's InstalledDir line
      name = "rbconfig";
      run = ''
        for f in (glob $"($c.out)/lib/ruby/*/*/rbconfig.rb") {
          let text = (open --raw $f
            | str replace -r '(CONFIG\["SHELL"\] = ")[^"]*' ("''${1}" + (dep-root bash "rbconfig SHELL") + "/bin/bash")
            | str replace -r '(CONFIG\["CC_VERSION_MESSAGE"\] = "[^"]*?)\\nInstalledDir: [^"]*' "''${1}")
          $text | save -f $f
        }
      '';
    }
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
