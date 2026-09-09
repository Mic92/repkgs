# mixed: go server embedding a vite-built UI from ui/; cgo against taglib, which the modules tree
# propagates (builder/sys-libs.nu)
{
  package,
  sources,
  fetch,
}:
package {
  name = "navidrome";
  uses = [
    "go"
    "npm"
  ];
  npm.root = "ui";
  npm.deps = fetch.npmDeps {
    source = sources.default;
    root = "ui";
  };
  go.tags = [
    "netgo"
    "sqlite_fts5"
  ];
  go.ldflags = [
    "-X github.com/navidrome/navidrome/consts.gitTag=v${sources.version}"
    "-X github.com/navidrome/navidrome/consts.gitSha=nix"
  ];
  go.packages = [ "." ];
  steps = [
    "npm.build"
    "go.build"
    "go.install"
  ]; # go tests want a music library fixture set
}
