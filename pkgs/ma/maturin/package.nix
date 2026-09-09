# PEP 517 backend for Rust extensions. Build tool only: no upload, sbom, completions, zig/xwin
{
  package,
}:
package {
  name = "maturin";
  uses = [ "cargo" ];
  cargo.noDefaultFeatures = true;
  steps = [
    "cargo.build"
    "cargo.install"
  ];
  bin = [ "maturin" ];
}
