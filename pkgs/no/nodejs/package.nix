# Node.js LTS with npm. V8, libuv, nghttp2, c-ares, ICU (small) stay bundled; zlib and openssl are ours.
{ package, pkgs }:
package {
  name = "nodejs";
  dependencies = [
    pkgs.zlib
    pkgs.openssl
  ];
  buildDependencies = [
    pkgs.cpython
    pkgs.ninja
  ];
  steps = [
    {
      name = "configure";
      run = ''
        let c = (ctx)
        # node's configure is a python script, not autoconf
        x python3 configure.py $"--prefix=($c.out)" --ninja --shared-zlib --shared-openssl --with-intl=small-icu --without-corepack
      '';
    }
    {
      name = "build";
      run = ''
        let c = (ctx)
        x ninja -C out/Release $"-j($c.njobs)"
      '';
    }
    {
      name = "install";
      run = ''
        let c = (ctx)
        x python3 tools/install.py install --dest-dir "" --prefix $c.out --build-dir out --config Release
      '';
    }
  ];
  tests.run = false; # hours
  tests.relocated = true;
  bin = [
    "node"
    "npm"
    "npx"
  ];
}
