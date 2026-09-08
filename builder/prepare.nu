# Everything before the first build-system verb: read the spec, export the dependency closure as
# search paths, unpack + patch the source (or restore a kept tree), lay out $out and the build
# dir, decide whether tests can run here, and publish it all as PKGS_CTX for `ctx`.
use core.nu *

def abs [d: record, field: string]: nothing -> list<string> { $d | get $field | each {|r| $"($d.root)/($r)" } }

# PATH, the toolchain's view of dependencies (CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH/…), compile-cache
# identity, prefix map, §4 default CFLAGS, deps' and the spec's `env`
def --env build-env [a: record, deps: list<record>, out: string]: nothing -> nothing {
  $env.PATH = ($a.buildDependencies | each { $"($in)/bin" })
  $env.HOME = $"($env.NIX_BUILD_TOP)/home"
  $env.TMPDIR = $env.NIX_BUILD_TOP
  $env.SOURCE_DATE_EPOCH = "315532800"  # 1980-01-01: earliest mtime ZIP (wheels, jars) can store
  $env.out = $out
  $env.JIG_LOG = $"($env.NIX_BUILD_TOP)/jig.log"
  # content identity: a rebuilt-but-identical toolchain or dependency (new store hash, same bytes)
  # still hits. The roots tell jig which concrete store dirs the masked header names map to.
  $env.JIG_STORE_IDENTITY = "content"
  $env.JIG_STORE_ROOTS = ($a.dependencies ++ $a.buildDependencies
    ++ (which cc | each {|c| open --raw ($c.path | path dirname | path dirname | path join etc/roots) | str trim })
    | str join " ")
  $env.CPPFLAGS = ($deps | each {|d| abs $d includeDirs } | flatten | each { $"-I($in)" } | str join " ")
  $env.LDFLAGS = (["-Wl,-z,relro,-z,now,-z,noexecstack,--as-needed"] ++ ($deps | each {|d| abs $d libDirs } | flatten | each { $"-L($in)" }) | str join " ")
  $env.PKG_CONFIG_PATH = ($deps | each {|d| abs $d pkgconfigDirs } | flatten | str join ":")
  $env.CMAKE_PREFIX_PATH = ($deps | get root | str join ";")
  $env.ACLOCAL_PATH = ($deps | each {|d| abs $d aclocalDirs } | flatten | str join ":")
  load-env {CC: cc, CXX: c++, AR: llvm-ar, RANLIB: llvm-ranlib, NM: llvm-nm, STRIP: llvm-strip}
  # no build/store paths in DWARF/__FILE__. Handed to the cc wrapper out of band so recorded CFLAGS stay clean
  $env.PKGS_PREFIX_MAP = ([[$env.NIX_BUILD_TOP "/build"]] ++ ($deps | each {|d| [$d.root $"/deps/($d.root | path basename | str substring 33..)"] })
    ++ ($a.buildDependencies | each { [$in $"/tools/($in | path basename | str substring 33..)"] })
    | each {|m| $"($m.0)=($m.1)" } | str join ":")
  # per-package defaults (§4): profiling-friendly, hardened. -march and the platform's hardening
  # flag are in the cc conf, so build systems that ignore CFLAGS still get them.
  $env.CFLAGS = (["-O2" "-fno-omit-frame-pointer" "-mno-omit-leaf-frame-pointer" "-g"
    "-D_FORTIFY_SOURCE=3" "-fstack-protector-strong" "-fstack-clash-protection" "-ftrivial-auto-var-init=zero"]
    ++ ($a.spec.cc?.cflags? | default []) | str join " ")
  $env.CXXFLAGS = $env.CFLAGS
  load-env ($deps | get env | reduce -f {} {|it, acc| $acc | merge $it })
  load-env ($a.spec.env? | default {})
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

# no /usr/bin/env in the sandbox. Rewrite only real matches: bumping every mtime makes autotools
# packages regenerate shipped files (coreutils' cu-progs.m4 -> aclocal)
def fix-env-shebangs [njobs: int]: nothing -> nothing {
  let env_bin = (tool env)
  let magic = ("#!/usr/bin/env" | into binary)
  glob "**/*" --no-dir --no-symlink | par-each --threads $njobs {|f|
    let m = (ls -l $f | first)
    if $m.size >= 1mb or ($m.mode | str substring 2..<3) != "x" { return }
    let bytes = (open --raw $f | into binary)
    if ($bytes | bytes starts-with $magic) {
      ($"#!($env_bin)" | into binary) ++ ($bytes | bytes at ($magic | bytes length)..) | save -f --raw $f
    }
  } | ignore
}

def --env unpack [a: record, src: path, njobs: int]: nothing -> nothing {
  note unpack $a.src
  # sources arrive unpacked (nix/sources.nix); a tarball only when a package says unpack = false.
  # -p: the store's uniform mtimes keep generated files "newer" than their inputs for make
  if ($a.src | path type) == "dir" { ^cp -rp $"($a.src)/." $src } else {
    ^bsdtar -xf $a.src -C $src --strip-components 1 --no-same-owner --no-same-permissions
  }
  ^chmod -R u+w $src
  cd $src
  for p in $a.patches { note patch $p; ^patch -p1 -i $p }
  fix-env-shebangs $njobs
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
  let deps = (dep-closure $a.dependencies)
  build-env $a $deps $out
  let plat = (resolve-platform $a.platform)

  let src = $"($env.NIX_BUILD_TOP)/source"
  let build = $"($env.NIX_BUILD_TOP)/build"
  mkdir $src $env.HOME
  let cache = ("/run/pkgs-cache.sock" | path exists)
  let ctx = {|testsRun| {spec: $spec, out: $out, deps: $deps, njobs: $njobs, src: $env.PWD, build: $build, platform: $plat, testsRun: $testsRun, cache: $cache} | to json -r }
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
