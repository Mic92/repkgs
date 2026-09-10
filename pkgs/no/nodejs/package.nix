# Node.js LTS with npm. V8, libuv, nghttp2, c-ares, ICU (small) stay bundled; zlib and openssl are ours.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "nodejs";
  dependencies = [
    pkgs.zlib
    pkgs.openssl
  ];
  buildDependencies = [
    buildPkgs.cpython
    buildPkgs.ninja
  ];
  patches = [ ./libcxx-includes.patch ];
  steps = [
    {
      name = "configure";
      run = ''
        # node's configure is a python script, not autoconf
        x python3 configure.py $"--prefix=($c.out)" --ninja --shared-zlib --shared-openssl --with-intl=small-icu --without-corepack
      '';
    }
    {
      name = "build";
      run = ''
        x ninja -C out/Release $"-j($c.njobs)"
      '';
    }
    {
      name = "install";
      run = ''
        x python3 tools/install.py install --dest-dir "" --prefix $c.out --build-dir out/Release
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
