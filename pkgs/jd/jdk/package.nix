# OpenJDK from source, headless (no X11 in the set yet), booted by jdk-bootstrap.
{
  package,
  pkgs,
  buildPkgs,
  platform,
}:
package {
  name = "jdk";
  dependencies = [
    pkgs.zlib
    pkgs.libpng
    pkgs.freetype
    pkgs.alsa-lib
    pkgs.libffi
    pkgs.cups-headers # headers only, for the target
    pkgs.fontconfig-headers
  ];
  buildDependencies = [
    buildPkgs.jdk-bootstrap
    buildPkgs.autoconf # the repo ships no generated configure
    buildPkgs.bash
    buildPkgs.zip
    buildPkgs.unzip
  ]
  ++ (if platform.cross then [ buildPkgs.jdk ] else [ ]);
  patches = [ ./riscv-float-type.patch ];
  phases = [
    {
      name = "configure";
      run = ''
        # jdk.jpackage uses std::nothrow without <new> (libstdc++ and older libc++ had it
        # transitively). tstrings.h is the header all of it includes
        let h = "src/jdk.jpackage/share/native/common/tstrings.h"
        open --raw $h | str replace "#include <string>" "#include <new>\n#include <string>" | save -f $h
        # not autotools proper: its own wrapper, and it wants bash
        let cross = (if $c.platform.cross {
          [$"--openjdk-target=($c.platform.triple)" $"--with-build-jdk=(tool-root jdk)" "BUILD_CC=cc-build" "BUILD_CXX=c++-build"]
        } else { [] })
        (x bash configure ...$cross
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
          # reproducible: fixed timestamps and "build user". jar --date rejects anything before
          # 1980-01-01T00:00:02Z (DOS time, 2 s granularity), two seconds past SOURCE_DATE_EPOCH
          --with-source-date=315532802 --with-hotspot-build-time=1980-01-01T00:00:02
          --with-build-user=pkgs)
      '';
    }
    {
      name = "build";
      run = "x make images JOBS=($c.njobs) LOG=info";
    }
    {
      name = "install";
      run = ''
        let img = (glob build/*/images/jdk | first)
        mkdir $c.out
        for d in [bin conf include jmods lib release] { cp -r $"($img)/($d)" $c.out }
      '';
    }
  ];
  bin = [
    "java"
    "javac"
    "jar"
  ];
  exports = false;
}
