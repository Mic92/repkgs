# Upstream's static Go toolchain, only ever a buildDependency of pkgs/go/go
{
  package,
}:
package {
  name = "go-bootstrap";
  # static binaries, nothing to implant: "ldso" just skips debug split and fixup without pulling in formatelf (and thereby rust)
  prebuilt = "ldso";
  steps = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        mkdir $c.out
        for d in [bin pkg src lib go.env VERSION] { mv $d $c.out }
      '';
    }
  ];
  bin = [ "go" ];
  tests.version = "version";
  exports = false;
}
