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
  cargo.tool = buildPkgs.rust-bootstrap;
  links."bin/auto-formatelf" = "formatelf";
  links."bin/patchelf" = "formatelf";
  bin = [
    "formatelf"
    "auto-formatelf"
  ];
}
