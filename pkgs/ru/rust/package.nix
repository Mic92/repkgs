# rustc + cargo + std from the rustc-src tarball, x.py driven by `rust-bootstrap` (upstream
# binaries, build-only), codegen through our libLLVM. std for the build machine's triple only:
# cross stds need each target's cc as x.py linker, later.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "rust";
  dependencies = [
    pkgs.llvm
    pkgs.zlib
    pkgs.openssl # cargo
  ];
  env.OPENSSL_NO_VENDOR = "1"; # cargo's openssl-sys: ours via pkg-config, not a vendored build
  buildDependencies = [
    buildPkgs.rust-bootstrap
    buildPkgs.cpython
    buildPkgs.cmake
    buildPkgs.ninja
    buildPkgs.pkgconf
  ];
  module = ./build.nu;
  steps = [
    "self.configure"
    "self.build"
    "self.install"
  ];
  tests.run = false; # x.py test: hours
  bin = [
    "rustc"
    "cargo"
  ];
  tests.version = "-V";
  tests.relocated = true;
  exports = false;
}
