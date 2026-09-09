# the VCS querying half of setuptools-scm, split out in setuptools-scm 10
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "python-vcs-versioning";
  uses = [ "python" ];
  python.module = "vcs_versioning";
  buildDependencies = [ buildPkgs.python-setuptools ];
  dependencies = [ pkgs.python-packaging ];
}
