{
  package,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "ncurses";
  uses = [ "autotools" ];
  # default terminfo dir relative to libtinfo. A terminfo entry cannot name a file relative to
  # itself, so the few with init files keep upstream's /usr/share/tabset
  patches = [ ./relocatable.patch ];
  # cross: the terminfo database is compiled by a tic that runs on the build machine
  buildDependencies = on platform.cross [ buildPkgs.ncurses ];
  # widec with the classic names as linker scripts, libtinfo split out (what ghc bindists NEED),
  # terminfo searched relative to nothing store-bound: $TERMINFO_DIRS and the usual system paths
  autotools.flags = [
    "--with-shared"
    "--without-debug"
    "--without-ada"
    "--enable-widec"
    "--with-versioned-syms"
    "--enable-pc-files"
    "--disable-stripping"
    "--with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo"
    "--with-manpage-format=normal"
  ]
  # the win32 terminal driver cannot live in a separate libtinfo
  ++ on (platform.os != "windows") [ "--with-termlib" ]
  ++ on (platform.os == "windows") [
    "--enable-term-driver"
    "--enable-sp-funcs"
  ]
  ++ on platform.cross [
    "--with-tic-path=${buildPkgs.ncurses}/bin/tic"
    "--with-infocmp-path=${buildPkgs.ncurses}/bin/infocmp"
  ];
  phases.replace."autotools.configure" = {
    name = "configure";
    run = ''
      # configure derives the .pc dir from pkg-config's search path otherwise
      $env.PKG_CONFIG_LIBDIR = $"($c.out)/lib/pkgconfig"
      $env.BUILD_CC = $env.CC_FOR_BUILD # cross: it guesses gcc
      autotools configure
    '';
  };
  phases.after."autotools.install" = [
    {
      name = "compat-links";
      run = ''
        let lib = $"($c.out)/lib"
        # -lncurses, -ltinfo etc. resolve to the wide variants
        for l in ([ncurses form panel menu] ++ (if $c.platform.os == "windows" { [] } else { [tinfo] })) {
          ^ln -sf (linklib $"($l)w") $"($lib)/(linklib $l)"
          if $c.platform.binfmt != "coff" { ^ln -sf (shlib $"($l)w" 6) $"($lib)/(shlib $l 6)" }
          ^ln -sf $"($l)w.pc" $"($lib)/pkgconfig/($l).pc"
        }
        # a #!$SHELL script duplicating the .pc files
        rm $"($c.out)/bin/ncursesw6-config"
      '';
    }
  ];
  tests.run = false; # interactive
  bin = [
    "tic"
    "tput"
    "infocmp"
  ];
  tests.version = "-V";
}
