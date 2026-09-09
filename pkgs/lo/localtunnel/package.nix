{
  package,
  pkgs,
  sources,
  fetch,
}:
package {
  name = "localtunnel";
  uses = [ "yarn" ];
  yarn.deps = fetch.yarnDeps { source = sources.default; };
  runtimeDependencies = [ pkgs.nodejs ];
  steps = [ "yarn.install" ]; # plain JS. The mocha tests open tunnels to localtunnel.me
  tests.version = "lt --version";
  bin = [ "lt" ];
}
