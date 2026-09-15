# patchelf reimplementation; `auto-formatelf` (argv[0] personality) gives foreign ELFs our
# interpreter and a RUNPATH resolved against given lib dirs. Used on binary wheels (builder/systems/pyapp.nu).
{
  package,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "formatelf";
  uses = [ "cargo" ];
  # finish.nu needs it on Linux before llvm + rust exist
  cargo = on (platform.os == "linux") { tool = buildPkgs.rust-bootstrap; };
  links."bin/auto-formatelf" = "formatelf";
  links."bin/patchelf" = "formatelf";
  bin = [
    "formatelf"
    "auto-formatelf"
  ];
}
