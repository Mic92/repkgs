{
  package,
  pkgs,
}:
package {
  name = "localtunnel";
  uses = [ "yarn" ];
  runtimeDependencies = [ pkgs.nodejs ];
  steps = [ "yarn.install" ]; # plain JS. The mocha tests open tunnels to localtunnel.me
  tests.version = "lt --version";
  bin = [ "lt" ];
}
