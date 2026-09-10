# std for the target triple, built by the finished rust (x.py, library only) and linked with the
# target cc. cargo.nu overlays it on rust's sysroot when cross compiling
{
  variant,
  pkgs,
  buildPkgs,
}:
variant pkgs.rust {
  dependencies.set = [ ];
  buildDependencies.set = [
    buildPkgs.rust
    buildPkgs.cpython
  ];
  phases.set = [
    "rust.stdConfigure"
    "rust.stdBuild"
    "rust.stdInstall"
  ];
  bin.set = [ ];
  tests.set = {
    run = false;
  };
}
