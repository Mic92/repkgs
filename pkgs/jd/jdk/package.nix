# OpenJDK from source, headless (no X11 in the set yet), booted by jdk-bootstrap.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "jdk";
  dependencies = [
    pkgs.zlib
    pkgs.libpng
    pkgs.freetype
    pkgs.alsa-lib
    pkgs.libffi
  ];
  buildDependencies = [
    buildPkgs.jdk-bootstrap
    buildPkgs.cups-headers
    buildPkgs.fontconfig-headers
    buildPkgs.bash
    buildPkgs.zip
    buildPkgs.unzip
  ];
  steps = [
    {
      name = "configure";
      run = ''
        let c = (ctx)
        # not autotools proper: its own wrapper, and it wants bash
        (x bash configure
          $"--prefix=($c.out)"
          $"--with-boot-jdk=(tool java | path dirname | path dirname)"
          --with-toolchain-type=clang
          --enable-headless-only
          --disable-warnings-as-errors
          --disable-precompiled-headers
          --with-native-debug-symbols=internal
          --with-stdc++lib=dynamic
          --with-zlib=system --with-libpng=system --with-freetype=system
          --with-giflib=bundled --with-libjpeg=bundled --with-lcms=bundled --with-harfbuzz=bundled
          $"--with-cups-include=(dep-root cups-headers cups)/include"
          $"--with-fontconfig-include=(dep-root fontconfig-headers fontconfig)/include"
          $"--with-jobs=($c.njobs)"
          --with-version-build=1 --with-version-pre= --with-version-opt=pkgs
          --with-vendor-name=pkgs
          # reproducible: no timestamps, fixed "build user"
          --with-source-date=1 --with-hotspot-build-time=1970-01-01T00:00:01
          --with-build-user=pkgs)
      '';
    }
    {
      name = "build";
      run = "x make images JOBS=((ctx).njobs) LOG=info";
    }
    {
      name = "install";
      run = ''
        let c = (ctx)
        let img = (glob build/*/images/jdk | first)
        for d in [bin conf include jmods lib release] { cp -r $"($img)/($d)" $c.out }
      '';
    }
  ];
  bin = [
    "java"
    "javac"
    "jar"
  ];
  tests.version = "--version";
  exports = false;
}
