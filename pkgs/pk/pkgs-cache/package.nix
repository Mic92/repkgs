# host-side daemon for jig's build cache. Run outside the sandbox: pkgs-cache /tmp/pkgs-cache.sock
{ package }:
package {
  name = "pkgs-cache";
  version = "2";
  source = ./src;
  uses = [ "go" ];
  go.cgo = false;
  steps = [
    "go.build"
    "go.install"
  ];
  bin = [ "pkgs-cache" ];
}
