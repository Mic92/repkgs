{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "meson";
  uses = [ "python" ];
  python.module = "mesonbuild";
  buildDependencies = [ buildPkgs.python-setuptools ];
  # bin/meson is `#!.../python3`: the interpreter is a run-time dependency, found via the launcher
  dependencies = [ pkgs.cpython ];
}
