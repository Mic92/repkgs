{
  package,
  sources,
  fetch,
  pkgs,
}:
package {
  name = "ripgrep";
  uses = [ "cargo" ];
  cargo.features = [ "pcre2" ];
  cargo.vendor = fetch.cargoVendor { source = sources.default; };
  dependencies = [ pkgs.pcre2 ];
  bin = [ "rg" ];
}
