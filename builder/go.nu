use core.nu *

# go build/test/install from a vendored module tree. Build cache via jig's GOCACHEPROG mode.
def knobs []: nothing -> record<tags: list<string>, ldflags: list<string>, packages: list<string>, root: string, vendor: any, cgo: bool> { knobs-for go {tags: [], ldflags: [], packages: ["./..."], root: ".", vendor: null, cgo: true} }

# offline vendored module mode, GOCACHEPROG through jig, cgo per `go.cgo`. Copies `go.vendor` in if the tree lacks one, after checking it matches go.sum
export def --env setup []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  load-env {
    GOCACHE: $"($c.build)/go-cache", GOPATH: $"($c.build)/go"
    GOFLAGS: "-mod=vendor -trimpath -buildvcs=false", GOPROXY: "off", GOSUMDB: "off", GOTOOLCHAIN: "local"
    CGO_ENABLED: (if $k.cgo { "1" } else { "0" })
    # cross: cc already targets the platform, go needs GOARCH; build-machine helpers use CC_FOR_BUILD
    GOOS: "linux", GOARCH: $c.platform.names.go
  }
  if $c.cache { $env.GOCACHEPROG = (tool gocacheprog) }
  cd $"($c.src)/($k.root)"
  if $k.vendor != null and not ("vendor" | path exists) {
    if (open --raw $"($k.vendor)/go.sum") != (open --raw go.sum) {
      error make {msg: "go.vendor was made from a different go.sum: the goModules hash is stale"}
    }
    ^cp -r $"($k.vendor)/vendor" vendor
    ^chmod -R u+w vendor
  }
}

# always link through cc so RUNPATH/interp policy and fixup apply to Go binaries too
def common-args [k: record]: nothing -> list<string> {
  [
    (if ($k.tags | is-not-empty) { $"-tags=($k.tags | str join ',')" })
    $"-ldflags=-linkmode=external ($k.ldflags | str join ' ')"
  ] | compact
}

# go build `go.packages` into the build dir (external linker = cc)
export def build []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  cd $"($c.src)/($k.root)"
  mkdir $"($c.build)/bin"
  x go build -p $c.njobs -o $"($c.build)/bin/" ...(common-args $k) ...$k.packages
}

# go test (`go.testPackages`, default `go.packages`)
export def test []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  if not $c.testsRun { return }
  cd $"($c.src)/($k.root)"
  x go test -p $c.njobs -vet=off ...(common-args $k) ...($k.testPackages? | default $k.packages)
}

# built binaries (or `bin` from the spec) -> $out/bin
export def install []: nothing -> nothing {
  let c = (ctx)
  mkdir $"($c.out)/bin"
  let bins = ($c.spec.bin? | default (ls $"($c.build)/bin" | get name | path basename))
  for b in $bins { cp $"($c.build)/bin/($b)" $"($c.out)/bin/($b)" }
}
