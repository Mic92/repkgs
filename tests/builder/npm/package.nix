{ package }:
package {
  name = "test-npm";
  version = "2.0.0";
  source = ./src;
  uses = [ "npm" ];
  npm.script = null;
  tests.version = "test-npm";
}
