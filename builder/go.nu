use core.nu *
use sys-libs.nu

# go build/test/install, modules from a GOPROXY=file:// tree (fetch.goModules) or the source's
# own vendor/. Build cache via jig's GOCACHEPROG mode.
def knobs []: nothing -> record<tags: list<string>, ldflags: list<string>, packages: list<string>, root: string, modules: any, cgo: bool> { knobs-for go {tags: [], ldflags: [], packages: ["./..."], root: ".", modules: null, cgo: true} }

# offline module resolution, GOCACHEPROG through jig, cgo per `go.cgo`
export def --env setup []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  load-env {
    GOCACHE: $"($c.build)/go-cache", GOPATH: $"($c.build)/go", GOSUMDB: "off", GOTOOLCHAIN: "local"
    GOFLAGS: $"-mod=(if $k.modules != null { 'mod' } else { 'vendor' }) -trimpath -buildvcs=false"
    GOPROXY: (if $k.modules != null { $"file://($k.modules)" } else { "off" })
    CGO_ENABLED: (if $k.cgo { "1" } else { "0" })
    # cross: cc already targets the platform, go needs GOARCH; build-machine helpers use CC_FOR_BUILD
    GOOS: "linux", GOARCH: $c.platform.names.go
  }
  if $c.cache { $env.GOCACHEPROG = (tool gocacheprog) }
  cd $"($c.src)/($k.root)"
}

# always link through cc so RUNPATH/interp policy and fixup apply to Go binaries too.
# cgo modules whose library the modules tree propagated get their "use the system one" tags (sys-libs.nu)
def common-args [k: record]: nothing -> list<string> {
  let tags = ($k.tags ++ (sys-libs go-tags (ctx).deps) | uniq)
  [
    (if ($tags | is-not-empty) { $"-tags=($tags | str join ',')" })
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
