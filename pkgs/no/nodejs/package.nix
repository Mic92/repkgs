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
    pkgs.zstd
    pkgs.brotli
    pkgs.libuv
    pkgs.nghttp2
    pkgs.c-ares
    pkgs.sqlite
  ];
  buildDependencies = [
    buildPkgs.cpython
    buildPkgs.ninja
  ];
  patches = [
    ./upstream-libcxx-includes.patch
    ./upstream-icu-emulator.patch
    ./v8-cfi-arm64.patch
    ./upstream-highway-rvv-baseline.patch
  ];
  phases = [
    "nodejs.configure"
    "nodejs.build"
    "nodejs.install"
  ];
  tests.run = false; # hours
  bin = [
    "node"
    "npm"
    "npx"
  ];
}
