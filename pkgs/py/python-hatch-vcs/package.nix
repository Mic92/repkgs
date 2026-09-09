{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "python-hatch-vcs";
  uses = [ "python" ];
  python.backend = "hatchling";
  python.module = "hatch_vcs";
  buildDependencies = [ buildPkgs.python-hatchling ];
  dependencies = [ pkgs.python-setuptools-scm ];
}
