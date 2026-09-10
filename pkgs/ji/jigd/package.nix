# host-side daemon for jig's build cache. Run outside the sandbox: jigd $XDG_RUNTIME_DIR/jigd/socket
{ package }:
package {
  name = "jigd";
  version = "3";
  source = ./src;
  uses = [ "go" ];
  go.cgo = false;
  tests.version = false; # a daemon, no --version
  phases = [
    "go.build"
    "go.install"
  ];
}
