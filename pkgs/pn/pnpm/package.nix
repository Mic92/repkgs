# pnpm's registry tarball is a bundled dist/ with no dependencies: copied, with
# bin/pnpm a launcher onto our node. A build tool (buildPkgs.pnpm in the pnpm build system).
{ package, pkgs }:
package {
  name = "pnpm";
  runtimeDependencies = [ pkgs.nodejs ];
  install."lib/node_modules/pnpm" = ".";
  links = {
    "bin/pnpm" = "../lib/node_modules/pnpm/bin/pnpm.cjs";
    "bin/pnpx" = "../lib/node_modules/pnpm/bin/pnpx.cjs";
  };
}
