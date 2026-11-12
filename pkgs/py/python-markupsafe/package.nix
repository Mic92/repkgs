{ package, buildPkgs }:
package {
  name = "python-markupsafe";
  uses = [ "python" ];
  python.module = "markupsafe";
  buildDependencies = [ buildPkgs.python-setuptools ];
}
