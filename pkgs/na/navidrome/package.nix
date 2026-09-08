# mixed: go server embedding a vite-built UI from ui/, cgo against taglib
{
  package,
  sources,
  fetch,
  pkgs,
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
  go.vendor = fetch.goModules {
    source = sources.default;
    hash = "sha256-lNjOVrlRD6ptDBpmfGYCN3Vkal9ACciOyS1RANzKYK4=";
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
  dependencies = [
    pkgs.taglib
    pkgs.zlib
  ];
  bin = [ "navidrome" ];
}
