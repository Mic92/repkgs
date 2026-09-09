# a Python application from uv.lock: wheels where the lock has compatible ones, pyyaml from sdist
# against our libyaml (sys-libs.nu), pydantic-core's binary wheel re-linked by auto-formatelf
{
  package,
  sources,
  fetch,
  pkgs,
  buildPkgs,
}:
package {
  name = "copier";
  uses = [ "pyapp" ];
  pyapp.deps = fetch.pythonDeps {
    source = sources.default;
    python = pkgs.cpython;
  };
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
  bin = [ "copier" ];
  tests.version = true;
}
