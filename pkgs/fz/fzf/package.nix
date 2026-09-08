{
  package,
  sources,
  fetch,
}:
package {
  name = "fzf";
  uses = [ "go" ];
  go.modules = fetch.goModules { source = sources.default; };
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
