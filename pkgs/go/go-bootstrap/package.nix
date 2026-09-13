# Upstream's static Go toolchain, only ever a buildDependency of pkgs/go/go
{
  package,
  platform,
}:
package {
  name = "go-bootstrap";
  source = "${platform.os}-${platform.cpu}";
  # static binaries, nothing to implant: "ldso" just skips debug split and fixup without pulling in formatelf (and thereby rust)
  prebuilt = "ldso";
  install."." = [
    "bin"
    "pkg"
    "src"
    "lib"
    "go.env"
    "VERSION"
  ];
  bin = [ "go" ];
  tests.version = "version";
  exports = false;
}
