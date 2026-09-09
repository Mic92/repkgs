{
  package,
  sources,
}:
package {
  name = "fzf";
  uses = [ "go" ];
  go.ldflags = [
    "-s"
    "-w"
    "-X main.version=${sources.version}"
    "-X main.revision=nix1"
  ];
  go.packages = [ "." ];
  go.testPackages = [
    "./src/algo/..."
    "./src/util/..."
    "./src/tui/..."
  ]; # src/ reader test spawns $SHELL
  bin = [ "fzf" ];
}
