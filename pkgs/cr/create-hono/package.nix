{
  package,
}:
package {
  name = "create-hono";
  uses = [ "bun" ];
  tests.run = false; # its tests prompt for a package manager and time out
  tests.version = true;
}
