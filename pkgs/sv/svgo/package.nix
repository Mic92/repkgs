{
  package,
  sources,
  fetch,
}:
package {
  name = "svgo";
  uses = [ "pnpm" ];
  pnpm.deps = fetch.pnpmDeps { source = sources.default; };
  bin = [ "svgo" ];
}
