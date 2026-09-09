# host-side daemon for jig's build cache. Run outside the sandbox: pkgs-cache /tmp/pkgs-cache.sock
{ package, fetch }:
package {
  name = "pkgs-cache";
  version = "3";
  source = ./src;
  uses = [ "go" ];
  go.deps = fetch.goModules { source = ./src; };
  go.cgo = false;
  steps = [
    "go.build"
    "go.install"
  ];
}
