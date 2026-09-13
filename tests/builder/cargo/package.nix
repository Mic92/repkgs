{ package }:
package {
  name = "test-cargo";
  version = "0.1.0";
  source = ./src;
  uses = [ "cargo" ];
  cargo.deps = null; # no third-party crates
  tests.version = "test-cargo";
}
