{ package }:
package {
  name = "ncurses";
  uses = [ "autotools" ];
  # widec with the classic names as linker scripts, libtinfo split out (what ghc bindists NEED),
  # terminfo searched relative to nothing store-bound: $TERMINFO_DIRS and the usual system paths
  autotools.flags = [
    "--with-shared"
    "--without-debug"
    "--without-ada"
    "--enable-widec"
    "--with-termlib"
    "--with-versioned-syms"
    "--enable-pc-files"
    "--disable-stripping"
    "--with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo"
    "--without-manpages"
  ];
  phases = [
    {
      name = "configure";
      run = ''
        # configure derives the .pc dir from pkg-config's search path otherwise
        $env.PKG_CONFIG_LIBDIR = $"($c.out)/lib/pkgconfig"
        $env.BUILD_CC = $env.CC_FOR_BUILD # cross: it guesses gcc
        autotools configure
      '';
    }
    "autotools.build"
    "autotools.install"
    {
      name = "compat-links";
      run = ''
        let lib = $"($c.out)/lib"
        # -lncurses, -ltinfo etc. resolve to the wide variants
        for l in [ncurses form panel menu tinfo] {
          $"INPUT\(-l($l)w)\n" | save -f $"($lib)/lib($l).so"
          ^ln -sf $"lib($l)w.so.6" $"($lib)/lib($l).so.6"
        }
        ^ln -sf ncursesw.pc $"($lib)/pkgconfig/ncurses.pc"
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
