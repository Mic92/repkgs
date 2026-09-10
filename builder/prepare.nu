# Everything before the first build-system phase: the environment (env.nu), the platform, the
# source tree (unpacked and patched, or restored for a tests derivation), and the `ctx` record
# every later step reads.
use core.nu *
use env.nu

# cross: does the builder's binfmt_misc run target binaries transparently (probe = target ld.so)?
# If not, build systems that support one get the explicit emulator
def --env resolve-platform [p: record]: nothing -> record {
  let transparent = ($p.cross and (try { (^$p.probe --version | complete).exit_code == 0 } catch { false }))
  if $p.cross { note platform $"($p.name) binfmt=($transparent)" }
  let plat = ($p | update emulator (if $transparent { [] } else { $p.emulator }) | insert transparent $transparent)
  load-env {CC_FOR_BUILD: (if $plat.cross { "cc-build" } else { "cc" }), PKGS_EMULATOR: ($plat.emulator | str join " ")}
  $plat
}

# sources arrive unpacked (nix/sources.nix). cp -p: the store's uniform mtimes keep generated
# files "newer" than their inputs for make
def --env unpack [a: record, src: path, njobs: int]: nothing -> nothing {
  note unpack $a.src
  ^cp -rp $"($a.src)/." $src
  ^chmod -R u+w $src
  cd $src
  for p in $a.patches { note patch $p; ^patch -p1 -i $p }
  fix-env-shebangs . $njobs
}

# tests derivation: the kept source+build tree back at the same absolute paths, so configured
# paths inside it stay valid
def --env restore [from_tree: string, src: path]: nothing -> nothing {
  note restore $from_tree
  ^bsdtar -xf $"($from_tree)/tree.tar.zst" -C $env.NIX_BUILD_TOP
  cd $src
}

export def --env main [
  --from-tree: string = ""  # tests derivation: restore the package's tree instead of unpacking
]: nothing -> nothing {
  let a = (attrs)
  let spec = $a.spec
  # in the tests derivation "$out" for build systems is the already-built package. Our own
  # output is just the log
  let out = (if $from_tree == "" { $a.outputs.out } else { $a.package })
  $env.PKGS_RESULT = $a.outputs.out
  let njobs = ($env.NIX_BUILD_CORES? | default "4" | into int)
  # the fetched trees of locked dependencies (`<bs>.deps`) are dependencies too: they propagate
  # the libraries their locked packages link (sys-libs.nu)
  let deps = (dep-closure ($a.dependencies ++ ($spec.uses? | default [] | each {|u| $spec | get -o $u | get -o deps } | compact)))
  env $a $deps $out
  let plat = (resolve-platform $a.platform)
  let cache = ($"($env.NIX_STORE | path dirname)/var/nix/jigd/socket" | path exists)
  if $cache { load-env (env compiler-caches) }

  let src = $"($env.NIX_BUILD_TOP)/source"
  let build = $"($env.NIX_BUILD_TOP)/build"
  mkdir $src $build
  if $from_tree == "" { unpack $a $src $njobs } else { restore $from_tree $src }
  cd ($spec.root? | default ".")

  # cross tests need transparent binfmt: every harness (libtool wrappers, meson runners, ctest
  # execute_process) execs target binaries somewhere an explicit emulator hook does not reach
  let wanted = ($spec.tests?.run? | default true)
  if $from_tree == "" and $wanted and $plat.cross and not $plat.transparent { note untested $"($plat.name): no binfmt on this builder" }
  let tests_run = ($from_tree != "" or ($wanted and ((not $plat.cross) or $plat.transparent)))
  $env.PKGS_CTX = {spec: $spec, out: $out, deps: $deps, roots: ($env.JIG_STORE_ROOTS | split row " "), njobs: $njobs, src: $env.PWD
    build: $build, platform: $plat, testsRun: $tests_run, cache: $cache}
}
