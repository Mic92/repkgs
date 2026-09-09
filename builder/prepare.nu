# Everything before the first build-system verb: read the spec, export the dependency closure as
# search paths, unpack + patch the source (or restore a kept tree), lay out $out and the build
# dir, decide whether tests can run here, and publish it all as PKGS_CTX for `ctx`.
use core.nu *

# every dependency's `field` dirs, absolute
# PATH, the toolchain's view of dependencies (CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH/…), compile-cache
# identity, prefix map, §4 default CFLAGS, deps' and the spec's `env`
def --env build-env [a: record, deps: list<record>, out: string]: nothing -> nothing {
  $env.PATH = ($a.buildDependencies | each { $"($in)/bin" })
  $env.HOME = $"($env.NIX_BUILD_TOP)/home"
  $env.TMPDIR = $env.NIX_BUILD_TOP
  # reproducibility pins: no wall clock, locale, timezone or hash randomisation in outputs
  $env.SOURCE_DATE_EPOCH = "315532800"  # 1980-01-01: earliest mtime ZIP (wheels, jars) can store
  load-env {TZ: "UTC", LC_ALL: "C.UTF-8", ZERO_AR_DATE: "1", PERL_HASH_SEED: "0", PYTHONHASHSEED: "0"
    KBUILD_BUILD_TIMESTAMP: "@315532800", KBUILD_BUILD_USER: "pkgs", KBUILD_BUILD_HOST: "pkgs", CONFIG_SITE: $a.CONFIG_SITE}
  $env.out = $out
  $env.JIG_LOG = $"($env.NIX_BUILD_TOP)/jig.log"
  $env.JIG_LOG_ARGS = $"($env.NIX_BUILD_TOP)/jig-uncached.log"
  # content identity: a rebuilt-but-identical toolchain or dependency (new store hash, same bytes)
  # still hits. The roots tell jig which concrete store dirs the masked header names map to.
  $env.JIG_STORE_IDENTITY = "content"
  $env.JIG_STORE_ROOTS = ($a.dependencies ++ $a.buildDependencies
    ++ (which cc | each {|c| open --raw ($c.path | path dirname | path dirname | path join etc/roots) | str trim })
    | str join " ")
  $env.CPPFLAGS = (dep-dirs $deps includeDirs | each { $"-I($in)" } | str join " ")
  $env.LDFLAGS = (["-Wl,-z,relro,-z,now,-z,noexecstack,--as-needed"] ++ (dep-dirs $deps libDirs | each { $"-L($in)" }) | str join " ")
  $env.PKG_CONFIG_PATH = (dep-dirs $deps pkgconfigDirs | str join ":")
  $env.CMAKE_PREFIX_PATH = ($deps | get root | str join ";")
  $env.ACLOCAL_PATH = (dep-dirs $deps aclocalDirs | str join ":")
  load-env {CC: cc, CXX: c++, AR: llvm-ar, RANLIB: llvm-ranlib, NM: llvm-nm, STRIP: llvm-strip}
  # no build/store paths in DWARF/__FILE__. Handed to the cc wrapper out of band so recorded CFLAGS stay clean
  let mask = {|p: string, under: string| $"($p)=/($under)/($p | path basename | str substring 33..)" }
  $env.PKGS_PREFIX_MAP = ([$"($env.NIX_BUILD_TOP)=/build"] ++ ($deps | get root | each { do $mask $in deps }) ++ ($a.buildDependencies | each { do $mask $in tools }) | str join ":")
  # per-package defaults (§4): profiling-friendly, hardened. -march and the platform's hardening
  # flag are in the cc conf, so build systems that ignore CFLAGS still get them. __DATE__/__TIME__
  # need no ban: clang derives them from SOURCE_DATE_EPOCH (set above)
  $env.CFLAGS = (["-O2" "-fno-omit-frame-pointer" "-mno-omit-leaf-frame-pointer" "-g"
    "-D_FORTIFY_SOURCE=3" "-fstack-protector-strong" "-fstack-clash-protection" "-ftrivial-auto-var-init=zero"]
    ++ ($a.spec.cc?.cflags? | default []) | str join " ")
  $env.CXXFLAGS = $env.CFLAGS
  load-env ($deps | get env | reduce -f {} {|it, acc| $acc | merge $it })
  load-env ($a.spec.env? | default {})
}

# cc always goes through jig. rustc and go only do when asked by environment, and they are run by
# more than their own build system (maturin and setuptools-rust from pyapp/python, cargo from
# napi-rs npm packages or gem extensions, `go build` from Makefiles), so ask here, not in cargo.nu/go.nu
def --env compiler-caches []: nothing -> nothing {
  if (which rustc | is-not-empty) {
    # RUSTC absolute so the wrapper's key names the toolchain; incremental artefacts are uncacheable
    load-env {RUSTC: (which rustc | first | get path), RUSTC_WRAPPER: (which rustcwrap | first | get path), CARGO_INCREMENTAL: "0"}
  }
  if (which go | is-not-empty) { $env.GOCACHEPROG = (which gocacheprog | first | get path) }
}

# cross: does the builder's binfmt_misc run target binaries transparently (probe = target ld.so)?
# If not, build systems that support one get the explicit emulator
def --env resolve-platform [p: record]: nothing -> record {
  let transparent = ($p.cross and (try { (^$p.probe --version | complete).exit_code == 0 } catch { false }))
  if $p.cross { note platform $"($p.name) binfmt=($transparent)" }
  let plat = ($p | update emulator (if $transparent { [] } else { $p.emulator }) | insert transparent $transparent)
  load-env {CC_FOR_BUILD: (if $plat.cross { "cc-build" } else { "cc" }), PKGS_EMULATOR: ($plat.emulator | str join " ")}
  $plat
}

def --env unpack [a: record, src: path, njobs: int]: nothing -> nothing {
  note unpack $a.src
  # sources arrive unpacked (nix/sources.nix). -p: the store's uniform mtimes keep generated
  # files "newer" than their inputs for make
  ^cp -rp $"($a.src)/." $src
  ^chmod -R u+w $src
  cd $src
  for p in $a.patches { note patch $p; ^patch -p1 -i $p }
  fix-env-shebangs . $njobs
}

export def --env main [
  --from-tree: string = ""  # tests derivation: restore source+build tree of the package instead of unpacking
]: nothing -> nothing {
  let a = (attrs)
  let spec = $a.spec
  # in the tests derivation "$out" for build systems is the already-built package, so configured
  # paths (install prefix baked into the build tree) stay valid. Our own output is just the log
  let out = (if $from_tree == "" { $a.outputs.out } else { $a.package })
  $env.PKGS_RESULT = $a.outputs.out
  let njobs = ($env.NIX_BUILD_CORES? | default "4" | into int)
  # lock-derived trees (cargo vendor, go modules, gems) are dependencies too: they propagate the
  # libraries their locked packages link (sys-libs.nu)
  let deps = (dep-closure ($a.dependencies ++ ([$a.spec.cargo?.vendor? $a.spec.go?.modules? $a.spec.bundler?.gems? $a.spec.pyapp?.deps? $a.spec.deno?.deps?] | compact)))
  build-env $a $deps $out
  let plat = (resolve-platform $a.platform)

  let src = $"($env.NIX_BUILD_TOP)/source"
  let build = $"($env.NIX_BUILD_TOP)/build"
  mkdir $src $env.HOME
  let cache = ("/run/pkgs-cache.sock" | path exists)
  if $cache { compiler-caches }
  let ctx = {|testsRun| {spec: $spec, out: $out, deps: $deps, njobs: $njobs, src: $env.PWD, build: $build, platform: $plat, testsRun: $testsRun, cache: $cache} }
  if $from_tree != "" {
    # same absolute paths as during the build (/build/source, /build/build), so generated files stay valid
    note restore $from_tree
    ^bsdtar -xf $"($from_tree)/tree.tar.zst" -C $env.NIX_BUILD_TOP
    cd $src; cd ($spec.root? | default ".")
    $env.PKGS_CTX = (do $ctx true)
    return
  }
  unpack $a $src $njobs
  cd ($spec.root? | default ".")
  mkdir $build
  # cross tests need transparent binfmt: every harness (libtool wrappers, meson runners, ctest
  # execute_process) execs target binaries somewhere an explicit emulator hook does not reach (§5)
  let wanted = ($spec.tests?.run? | default true)
  if $wanted and $plat.cross and not $plat.transparent { note untested $"($plat.name): no binfmt on this builder" }
  $env.PKGS_CTX = (do $ctx ($wanted and ((not $plat.cross) or $plat.transparent)))
}
