{
  package,
  platform,
}:
package (
  {
    name = "cmake";
    tests.run = false; # ≈1 h
    tests.relocated = true;
    bin = [
      "cmake"
      "ctest"
      "cpack"
    ];
  }
  // (
    if platform.cross then
      {
        # configured by the build machine's cmake (the cmake build system brings it)
        uses = [ "cmake" ];
        cmake.defs = {
          CMAKE_USE_OPENSSL = false;
          CMAKE_USE_SYSTEM_LIBRARIES = false;
        };
      }
    else
      {
        uses = [ "autotools" ];
        # ./bootstrap builds a minimal cmake with make, then cmake configures itself. Bundled libs: zlib &
        # co. are cmake packages themselves, using ours would be a cycle
        autotools.configureScript = "bootstrap";
        phases = [
          {
            name = "configure";
            run = ''
              cd $c.build
              (x $env.CONFIG_SHELL $"($c.src)/bootstrap" $"--prefix=($c.out)" $"--parallel=($c.njobs)" --no-system-libs
                --no-qt-gui --docdir=share/doc/cmake --mandir=share/man
                -- -DCMAKE_USE_OPENSSL=OFF -DBUILD_TESTING=OFF -DCMake_BUILD_LTO=OFF $"-DCMAKE_SYSTEM_PREFIX_PATH=($c.platform.sysroot)")
            '';
          }
          "autotools.build"
          "autotools.install"
        ];
      }
  )
)
