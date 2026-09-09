# Deno Deploy's CLI; first user of the deno build system (jsr, npm and https: modules in its lock)
{
  package,
  pkgs,
}:
package {
  name = "deployctl";
  uses = [ "deno" ];
  deno.entry.deployctl = "deployctl.ts";
  tests.run = false; # talks to dash.deno.com
  deno.check = false; # 1.x sources against deno 2 lib typings (Timeout, Uint8Array<ArrayBufferLike>)
  dependencies = [ pkgs.deno ];
  tests.version = true;
}
