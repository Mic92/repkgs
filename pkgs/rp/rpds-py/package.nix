# mixed: python (maturin backend) + cargo in one tree
{
  package,
  sources,
  fetch,
  buildPkgs,
}:
package {
  name = "rpds-py";
  uses = [
    "python"
    "cargo"
  ];
  python.backend = "maturin";
  python.module = "rpds";
  cargo.vendor = fetch.cargoVendor { source = sources.default; };
  steps = [
    "python.build"
    "python.install"
    "python.test"
  ];
  buildDependencies = [ buildPkgs.maturin ];
}
