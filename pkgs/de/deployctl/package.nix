# Deno Deploy's CLI; first user of the deno build system (jsr, npm and https: modules in its lock)
{
  package,
  pkgs,
}:
package {
  name = "deployctl";
  uses = [ "deno" ];
  deno.entry.deployctl = "deployctl.ts";
  deno.test = false; # talks to dash.deno.com
  dependencies = [ pkgs.deno ];
  bin = [ "deployctl" ];
  tests.version = true;
}
