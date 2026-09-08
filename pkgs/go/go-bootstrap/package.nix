# Upstream's static Go toolchain, only ever a buildDependency of pkgs/go/go
{
  package,
  platform,
  sources,
}:
package {
  name = "go-bootstrap";
  source = sources.fetch platform.cpu;
  prebuilt = true;
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
  exports = {
    libDirs = [ ];
    libs = [ ];
  };
}
