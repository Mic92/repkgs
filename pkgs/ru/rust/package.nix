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
  dependencies = [ pkgs.llvm22 ]; # the major rustc bundles and is tested with. Ours is one ahead
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
