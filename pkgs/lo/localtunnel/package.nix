{
  package,
}:
package {
  name = "localtunnel";
  uses = [ "yarn" ];
  phases = [ "yarn.install" ]; # plain JS. The mocha tests open tunnels to localtunnel.me
  bin = [ "lt" ];
}
