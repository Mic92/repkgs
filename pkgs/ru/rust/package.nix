# rustc + cargo + std from the rustc-src tarball, x.py driven by `rust-bootstrap` (upstream
# binaries, build-only), codegen through our libLLVM.
{
  package,
  pkgs,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "rust";
  dependencies = [
    pkgs.llvm22 # the major rustc bundles and is tested with; ours is one ahead
    pkgs.zlib
    pkgs.openssl # cargo
  ];
  env.OPENSSL_NO_VENDOR = "1"; # cargo's openssl-sys: ours via pkg-config, not a vendored build
  # cross: stage1 runs here and links the build machine's libLLVM
  buildDependencies = on platform.cross [ buildPkgs.llvm22 ] ++ [
    buildPkgs.rust-bootstrap
    buildPkgs.cpython
    buildPkgs.cmake
    buildPkgs.ninja
    buildPkgs.pkgconf
  ];
  phases = [
    "rust.configure"
    "rust.build"
    "rust.install"
  ];
  tests.run = false; # x.py test: hours
  bin = [
    "rustc"
    "cargo"
  ];
  tests.version = "-V";
  exports = false;
}
