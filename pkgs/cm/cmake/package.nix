{ package }:
package {
  name = "cmake";
  uses = [ "autotools" ];
  # ./bootstrap builds a minimal cmake with make, then cmake configures itself. Bundled libs: zlib &
  # co. are cmake packages themselves, using ours would be a cycle
  autotools.configureScript = "bootstrap";
  steps = [
    {
      name = "configure";
      run = ''
        let c = (ctx)
        cd $c.build
        (x $env.CONFIG_SHELL $"($c.src)/bootstrap" $"--prefix=($c.out)" $"--parallel=($c.njobs)" --no-system-libs
          --no-qt-gui --docdir=share/doc/cmake --mandir=share/man
          -- -DCMAKE_USE_OPENSSL=OFF -DBUILD_TESTING=OFF -DCMake_BUILD_LTO=OFF)
      '';
    }
    "autotools.build"
    "autotools.install"
  ];
  tests.run = false; # ≈1 h
  tests.relocated = true;
  bin = [
    "cmake"
    "ctest"
    "cpack"
  ];
}
