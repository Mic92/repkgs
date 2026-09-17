# a Python application from uv.lock: wheels where the lock has compatible ones, pyyaml from sdist
# against our libyaml (sys-libs), pydantic-core from sdist to exercise Rust sdists (crates
# vendored by fetch/pypi-vendor.nu, maturin + our rustc)
{
  package,
  sources,
  fetch,
  pkgs,
}:
package {
  name = "copier";
  uses = [ "pyapp" ];
  pyapp = {
    check = [ "copier" ];
    deps = fetch.pythonDeps {
      source = sources.fetch "default";
      python = pkgs.cpython;
      sdist = [ "pydantic-core" ];
    };
  };
  dependencies = [ pkgs.cpython ];
  env.SETUPTOOLS_SCM_PRETEND_VERSION = sources.version;
  tests.version = true;
}
