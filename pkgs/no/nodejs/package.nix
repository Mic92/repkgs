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
  patches = [
    ./libcxx-includes.patch
    ./icu-emulator.patch
  ];
  phases = [
    {
      name = "configure";
      run = ''
        # configure.py, not autoconf. Cross: code generators like mksnapshot are built for the
        # target and run under qemu (--emulator). The alternative, gyp's host toolset, generates
        # a broken ninja file (two rules for js_protocol.stamp)
        let emulator = (if ($c.platform.emulator | is-empty) { [] } else { [$"--emulator=($c.platform.emulator | str join ' ')"] })
        let cross = (if $c.platform.cross { [$"--dest-cpu=($c.platform.names.gyp)" --dest-os=linux ...$emulator] } else { [] })
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
