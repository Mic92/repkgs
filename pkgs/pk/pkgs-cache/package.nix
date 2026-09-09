# host-side daemon for jig's build cache. Run outside the sandbox: pkgs-cache /tmp/pkgs-cache.sock
{ package }:
package {
  name = "pkgs-cache";
  version = "3";
  source = ./src;
  uses = [ "go" ];
  go.cgo = false;
  tests.version = false; # a daemon, no --version
  steps = [
    "go.build"
    "go.install"
  ];
}
