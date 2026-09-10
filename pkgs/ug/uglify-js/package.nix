{
  package,
  sources,
  fetch,
}:
package {
  name = "uglify-js";
  uses = [ "npm" ];
  # upstream ships no lockfile
  npm.deps = fetch.npmDeps {
    source = sources.default;
    lockFile = ./package-lock.json;
  };
  phases = [ "npm.install" ]; # plain JS, nothing to build; its tests take minutes
  bin = [ "uglifyjs" ];
}
