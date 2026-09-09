# yarn classic's registry tarball is a bundled lib/cli.js with no dependencies: copied, bin/yarn
# onto our node. A build tool (buildPkgs.yarn in the yarn build system).
{ package, pkgs }:
package {
  name = "yarn";
  runtimeDependencies = [ pkgs.nodejs ];
  steps = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        let dst = $"($c.out)/lib/node_modules/yarn"
        mkdir ($dst | path dirname) $"($c.out)/bin"
        ^cp -r . $dst
        for b in [yarn yarnpkg] { ^ln -s $"($dst)/bin/yarn.js" $"($c.out)/bin/($b)" }
      '';
    }
  ];
  tests.version = "yarn --version";
  bin = [ "yarn" ];
}
