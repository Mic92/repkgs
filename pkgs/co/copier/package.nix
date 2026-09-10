# a Python application from uv.lock: wheels where the lock has compatible ones, pyyaml from sdist
# against our libyaml (sys-libs.nu), pydantic-core's binary wheel given our ld.so and RUNPATH by implant.nu
{
  package,
  sources,
  pkgs,
  buildPkgs,
}:
package {
  name = "copier";
  uses = [ "pyapp" ];
  pyapp.check = [ "copier" ];
  buildDependencies = [
    buildPkgs.python-hatch-vcs
    buildPkgs.python-cython
  ];
  dependencies = [
    pkgs.cpython
    pkgs.libgcc-shim
  ];
  env.SETUPTOOLS_SCM_PRETEND_VERSION = sources.version;
  tests.version = true;
}
