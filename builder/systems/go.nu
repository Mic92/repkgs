use ../core.nu *
use ../sys-libs.nu

# go build/test/install, modules from a GOPROXY=file:// tree (fetch.goModules, `go.deps`) or,
# with `go.deps = null`, the source's own vendor/.
# offline module resolution, cgo per `go.cgo`
export def --env setup []: nothing -> nothing {
  let c = (ctx); let o = (options go)
  load-env {
    GOCACHE: $"($c.build)/go-cache", GOPATH: $"($c.build)/go", GOSUMDB: "off", GOTOOLCHAIN: "local"
    # compile/asm/link take a host-wide jigd slot like cc and rustc do (jig slot)
    GOFLAGS: $"-mod=(if $o.deps != null { 'mod' } else { 'vendor' }) -trimpath -buildvcs=false '-toolexec=(tool jig) slot'"
    GOPROXY: (if $o.deps != null { $"file://($o.deps)" } else { "off" })
    # cgo reads CGO_CPPFLAGS/CGO_LDFLAGS, not CPPFLAGS/LDFLAGS: dependencies' include and lib dirs
    CGO_ENABLED: (if $o.cgo { "1" } else { "0" }), CGO_CPPFLAGS: ($env.CPPFLAGS? | default ""), CGO_LDFLAGS: ($env.LDFLAGS? | default "")
    # cross: cc already targets the platform, go needs GOARCH; build-machine helpers use CC_FOR_BUILD
    GOOS: "linux", GOARCH: $c.platform.names.go
  }
}

export def workdir []: nothing -> string { project-dir go }

# cgo builds link through cc so RUNPATH/interp policy and fixup apply (cgo=false: static, internal linker).
# cgo modules whose library the modules tree propagated get their "use the system one" tags (sys-libs.nu)
def common-args [o: record<tags: list<string>, ldflags: list<string>, cgo: bool, flags: list<string>>]: nothing -> list<string> {
  let tags = ($o.tags ++ (sys-libs go-tags (ctx).deps) | uniq)
  [
    (if ($tags | is-not-empty) { $"-tags=($tags | str join ',')" })
    $"-ldflags=((if $o.cgo { ['-linkmode=external'] } else { [] }) ++ $o.ldflags | str join ' ')"
  ] | compact | append $o.flags
}

# go build `go.packages` into the build dir (external linker = cc)
export def build []: nothing -> nothing {
  let c = (ctx); let o = (options go)
  mkdir $"($c.build)/bin"
  x go build $"-p=($c.njobs)" -o $"($c.build)/bin/" ...(common-args $o) ...$o.packages
}

# go test (`go.testPackages`, default `go.packages`), tests.parallel as -p/-parallel, go.skipTests as -skip
export def test []: nothing -> nothing {
  let o = (options go)
  let skip = (if ($o.skipTests | is-empty) { [] } else { [-skip ($o.skipTests | str join '|')] })
  x go test -p (test-jobs) -parallel (test-jobs) -vet=off ...$skip ...(common-args $o) ...($o.testPackages | default $o.packages)
}

# the executables go built -> $out/bin (those in `bin` when the spec names some)
export def install []: nothing -> nothing {
  let c = (ctx)
  let built = (ls $"($c.build)/bin" | get name | path basename)
  install-bins $"($c.build)/bin" ($built | where { $c.spec.bin? == null or $in in $c.spec.bin })
}
