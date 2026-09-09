{
  package,
}:
package {
  name = "python-pathspec";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "pathspec";
}
