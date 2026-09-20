{
  package,
  pkgs,
  platform,
  on,
}:
package {
  name = "readline";
  uses = [ "autotools" ];
  autotools.flags = [
    "--with-curses"
    "--with-shared-termcap-library"
  ]
  ++ on (platform.os == "windows") [ "CFLAGS=-D__USE_MINGW_ALARM -D_POSIX" ];
  # shobj-conf says --export-all, lld only knows the long spelling
  autotools.makeFlags = on (platform.os == "windows") [
    "SHOBJ_LDFLAGS=-shared -Wl,--export-all-symbols -Wl,--enable-auto-import"
  ];
  # msys2's, all behind __MINGW32__/_WIN32
  patches = [
    ./mingw-0001-sigwinch.patch
    ./mingw-0002-event-hook.patch
    ./mingw-0003-no-winsize.patch
    ./mingw-0004-locale.patch
  ];
  dependencies = [ pkgs.ncurses ];
}
