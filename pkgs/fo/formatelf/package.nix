# patchelf reimplementation; `auto-formatelf` (argv[0] personality) gives foreign ELFs our
# interpreter and a RUNPATH resolved against given lib dirs. Used on binary wheels (builder/uv.nu).
{
  package,
}:
package {
  name = "formatelf";
  uses = [ "cargo" ];
  steps = [
    "cargo.build"
    "cargo.test"
    "cargo.install"
    {
      name = "personalities";
      run = "for n in [auto-formatelf patchelf] { ^ln -s formatelf $\"((ctx).out)/bin/($n)\" }";
    }
  ];
  bin = [
    "formatelf"
    "auto-formatelf"
  ];
  tests.version = true;
}
