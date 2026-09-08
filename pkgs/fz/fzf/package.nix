{
  package,
  sources,
  fetch,
}:
package {
  name = "fzf";
  uses = [ "go" ];
  go.vendor = fetch.goModules {
    source = sources.default;
    hash = "sha256-NojjUf/3c4q4B96eQ/qcI+GdRvHakHUyMRaQ6/IZpEw=";
  };
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
