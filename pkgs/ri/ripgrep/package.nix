{
  package,
  sources,
  fetch,
}:
package {
  name = "ripgrep";
  uses = [ "cargo" ];
  cargo.features = [ "pcre2" ];
  cargo.vendor = fetch.cargoVendor { source = sources.default; }; # brings pcre2 for pcre2-sys
  bin = [ "rg" ];
}
