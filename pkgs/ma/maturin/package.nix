# PEP 517 backend for Rust extensions. Build tool only: no upload, sbom, completions, zig/xwin
{
  package,
  sources,
  fetch,
}:
package {
  name = "maturin";
  uses = [ "cargo" ];
  cargo.vendor = fetch.cargoVendor { source = sources.default; };
  cargo.noDefaultFeatures = true;
  steps = [
    "cargo.build"
    "cargo.install"
  ];
  bin = [ "maturin" ];
}
