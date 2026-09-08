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
  steps = [ "npm.install" ]; # plain JS, nothing to build; its tests take minutes
  # `#!/usr/bin/env node`: needs pkgs.nodejs as runtimeDependency + launcher (wave 7)
  tests.version = false;
  bin = [ "uglifyjs" ];
}
