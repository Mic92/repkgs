# git without the perl, python and tcl parts (send-email, svn, p4, gitk, git-gui) and without
# gettext. `configure` only records prefix, compiler and library locations into config.mak.autogen
{ package, pkgs }:
package {
  name = "git";
  uses = [ "autotools" ];
  autotools.outOfTree = false;
  autotools.flags = [
    "--with-curl"
    "--with-expat"
    "--with-libpcre2"
    "--without-tcltk"
  ];
  autotools.makeFlags = [
    "NO_PERL=1"
    "NO_PYTHON=1"
    "NO_GETTEXT=1"
    "NO_INSTALL_HARDLINKS=1"
    "INSTALL_SYMLINKS=1"
  ];
  autotools.testTarget = "-C t T=t0001-init.sh"; # the full suite is an hour. One script proves the harness and binary work
  dependencies = [
    pkgs.zlib
    pkgs.curl
    pkgs.expat
    pkgs.pcre2
    pkgs.openssl
  ];
  tests.relocated = true;
}
