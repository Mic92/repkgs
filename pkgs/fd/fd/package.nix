{
  package,
  sources,
  fetch,
}:
package {
  name = "fd";
  uses = [ "cargo" ];
  cargo.vendor = fetch.cargoVendor { source = sources.default; };
  bin = [ "fd" ];
}
