{
  package,
}:
package {
  name = "create-hono";
  uses = [ "bun" ];
  bun.script = "build";
  tests.version = true;
}
