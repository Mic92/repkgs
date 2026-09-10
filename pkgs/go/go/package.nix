# Go from source, bootstrapped with go-bootstrap. cgo goes through our cc
{
  package,
  buildPkgs,
  sources,
}:
package {
  name = "go";
  source = sources.default;
  buildDependencies = [ buildPkgs.go-bootstrap ];
  phases = [
    {
      name = "build";
      run = ''
        $env.GOROOT_BOOTSTRAP = $"(which go | get 0.path | path dirname)/.."
        $env.GOROOT_FINAL = $c.out
        $env.GOCACHE = $"($c.build)/go-cache"
        $env.GOFLAGS = "-trimpath"
        if $c.cache { $env.GOCACHEPROG = (which gocacheprog | get 0.path) }
        $env.CC = "cc"
        cd src
        x sh make.bash
        cd ..
        mkdir $c.out
        # pkg/obj and the bootstrap dist tool are build leftovers
        rm -rf pkg/obj pkg/bootstrap
        for d in [bin pkg src lib misc go.env VERSION] { ^cp -r $d $c.out }
        # testdata: 40MB nothing at runtime reads
        for t in (glob $"($c.out)/src/**/testdata") { rm -rf $t }
      '';
    }
  ];
  bin = [
    "go"
    "gofmt"
  ];
  tests.version = "version";
  exports = false;
}
