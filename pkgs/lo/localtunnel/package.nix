{
  package,
}:
package {
  name = "localtunnel";
  uses = [ "yarn" ];
  steps = [ "yarn.install" ]; # plain JS. The mocha tests open tunnels to localtunnel.me
  bin = [ "lt" ];
}
