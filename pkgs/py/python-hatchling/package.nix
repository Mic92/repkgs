# builds itself: python.nu puts the source's src/ on PYTHONPATH so `hatchling.build` is importable
{
  package,
  pkgs,
}:
package {
  name = "python-hatchling";
  uses = [ "python" ];
  python.backend = "hatchling";
  python.module = "hatchling";
  dependencies = [
    pkgs.cpython # bin/hatchling runs under it
    pkgs.python-packaging
    pkgs.python-pathspec
    pkgs.python-pluggy
    pkgs.python-trove-classifiers
  ];
  bin = [ "hatchling" ];
  tests.version = false; # no --version, `hatchling version` reports the project's
}
