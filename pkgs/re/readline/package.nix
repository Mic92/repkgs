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
  # msys2's, all behind __MINGW32__/_WIN32
  patches = [
    ./mingw-0001-sigwinch.patch
    ./mingw-0002-event-hook.patch
    ./mingw-0003-no-winsize.patch
    ./mingw-0004-locale.patch
  ];
  dependencies = [ pkgs.ncurses ];
}
