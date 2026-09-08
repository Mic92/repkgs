# pnpm 10's registry tarball is a single bundled dist/pnpm.cjs with no dependencies: copied, with
# bin/pnpm a launcher onto our node. A build tool (buildPkgs.pnpm in the pnpm build system).
{ package, pkgs }:
package {
  name = "pnpm";
  runtimeDependencies = [ pkgs.nodejs ];
  steps = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        let dst = $"($c.out)/lib/node_modules/pnpm"
        mkdir ($dst | path dirname) $"($c.out)/bin"
        ^cp -r . $dst
        for b in [pnpm pnpx] { ^ln -s $"($dst)/bin/($b).cjs" $"($c.out)/bin/($b)" }
      '';
    }
  ];
  tests.version = "pnpm --version";
  bin = [ "pnpm" ];
}
