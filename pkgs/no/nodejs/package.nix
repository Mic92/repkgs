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
  phases = [
    {
      name = "configure";
      run = ''
        # a python script, not autoconf. gyp's host toolset (icupkg, mksnapshot) takes CC_host
        let cross = (if $c.platform.cross {
          load-env {CC_host: "cc-build", CXX_host: "c++-build", AR_host: "llvm-ar"}
          [--cross-compiling $"--dest-cpu=($c.platform.names.gyp)" --dest-os=linux]
        } else { [] })
        x python3 configure.py $"--prefix=($c.out)" --ninja --shared-zlib --shared-openssl --with-intl=small-icu --without-corepack ...$cross
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
