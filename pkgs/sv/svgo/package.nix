{
  package,
}:
package {
  name = "svgo";
  uses = [ "pnpm" ];
  phases.replace."pnpm.test" = {
    # test/regression diffs against a `git rev-parse HEAD` baseline, no repo in a tarball
    name = "test";
    run = "x pnpm exec vitest run --exclude test/regression";
  };
}
