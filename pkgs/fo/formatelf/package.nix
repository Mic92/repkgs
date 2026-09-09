# patchelf reimplementation; `auto-formatelf` (argv[0] personality) gives foreign ELFs our
# interpreter and a RUNPATH resolved against given lib dirs. Used on binary wheels (builder/systems/pyapp.nu).
{
  package,
  buildPkgs,
}:
package {
  name = "formatelf";
  uses = [ "cargo" ];
  # tree infrastructure (finish.nu implants prebuilt ELFs with it): must not wait for llvm + rust
  cargo.toolchain = buildPkgs.rust-bootstrap;
  steps = [
    "cargo.build"
    "cargo.test"
    "cargo.install"
    {
      name = "personalities";
      run = "for n in [auto-formatelf patchelf] { ^ln -s formatelf $\"($c.out)/bin/($n)\" }";
    }
  ];
  bin = [
    "formatelf"
    "auto-formatelf"
  ];
}
