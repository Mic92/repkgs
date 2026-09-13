{ package }:
package {
  name = "test-go";
  version = "1";
  source = ./src;
  uses = [ "go" ];
  go.packages = [ "." ];
  go.deps = null; # no third-party modules, no go.sum
  tests.version = "hello";
}
