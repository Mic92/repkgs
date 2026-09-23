{
  package,
  pkgs,
}:
package {
  name = "python-jinja2";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "jinja2";
  dependencies = [ pkgs.python-markupsafe ];
}
