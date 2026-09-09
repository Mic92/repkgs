{ package }:
package {
  name = "ripgrep";
  uses = [ "cargo" ];
  cargo.features = [ "pcre2" ];
  bin = [ "rg" ];
}
