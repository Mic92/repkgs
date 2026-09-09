{
  package,
  sources,
  fetch,
}:
package {
  name = "create-hono";
  uses = [ "bun" ];
  bun.deps = fetch.bunDeps { source = sources.default; };
  bun.script = "build";
  bin = [ "create-hono" ];
  tests.version = true;
}
