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
      name = "install";
      run = ''
        let c = (ctx)
        for d in [bin conf include jmods lib release] { cp -r $d $c.out }
        # X11 AWT and its dependents would fail the implant for want of libX11 & co
        rm ...(glob $"($c.out)/lib/{libawt_xawt,libsplashscreen,libjawt}.so")
      '';
    }
  ];
  bin = [
    "java"
    "javac"
  ];
  tests.version = "--version";
  exports = false;
}
