{
  package,
  pkgs,
}:
package {
  name = "jq";
  uses = [ "autotools" ];
  autotools.flags = [
    "--with-oniguruma=yes"
    "--disable-docs"
    "--disable-maintainer-mode"
  ];
  autotools.testTarget = "check TESTS=tests/jqtest"; # shtest wants a tty and /dev/stdin tricks
  tests.separate = true;
  dependencies = [ pkgs.oniguruma ];
}
