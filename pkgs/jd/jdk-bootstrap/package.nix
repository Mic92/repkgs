# Temurin's OpenJDK under our dynamic linker: the boot JDK for pkgs/jd/jdk (building OpenJDK N
# takes a JDK N or N-1). Build tool only.
{
  package,
  pkgs,
}:
package {
  name = "jdk-bootstrap";
  prebuilt = true;
  # what libawt/libfontmanager/libjsound link. The X11 ones are absent: javac never loads them
  dependencies = [
    pkgs.zlib
    pkgs.alsa-lib
    pkgs.freetype
  ];
  steps = [
    {
      # X11 AWT and its dependents would fail the implant for want of libX11 & co
      name = "prune";
      run = "rm lib/libawt_xawt.so lib/libsplashscreen.so lib/libjawt.so";
    }
  ];
  install."." = [
    "bin"
    "conf"
    "include"
    "jmods"
    "lib"
    "release"
  ];
  bin = [
    "java"
    "javac"
  ];
  exports = false;
}
