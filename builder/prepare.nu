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
  # qemu-user otherwise hands out guest mappings above 2^48 (mmap hints from V8's code range land
  # there), where a real arm64 process has no addresses and PAC keeps its signature, so signed
  # return addresses stop authenticating. binfmt-registered qemu reads it too
  let qemu = (if $p.cross { {QEMU_RESERVED_VA: "0x1000000000000"} } else { {} })
  load-env ((build-machine-tools $plat) | merge {PKGS_EMULATOR: ($plat.emulator | str join " ")} | merge $qemu)
  $plat
}

# The *_FOR_BUILD convention (AX_PROG_CC_FOR_BUILD, glib, meson's native file reads the same
# names through meson.nu): build-machine compiler, no target flags, and a pkg-config that finds
# nothing rather than target libraries. cc-rs and pkg-config-rs (build scripts, proc macros)
# read the same per triple as <VAR>_<build triple>
def build-machine-tools [plat: record]: nothing -> record {
  if not $plat.cross { return {CC_FOR_BUILD: "cc", CXX_FOR_BUILD: "c++", CPP_FOR_BUILD: "cc -E", PKG_CONFIG_FOR_BUILD: "pkg-config"} }
  let dir = $"($env.NIX_BUILD_TOP)/for-build"
  mkdir $"($dir)/no-pc"
  $"#!/bin/sh\nPKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=($dir)/no-pc exec pkg-config \"$@\"\n" | save -f $"($dir)/pkg-config"
  chmod +x $"($dir)/pkg-config"
  let rs = ($plat.buildRustTriple | str replace -a "-" "_")
  {CC_FOR_BUILD: "cc-build", CXX_FOR_BUILD: "c++-build", CPP_FOR_BUILD: "cc-build -E", PKG_CONFIG_FOR_BUILD: $"($dir)/pkg-config"
    CFLAGS_FOR_BUILD: "", CXXFLAGS_FOR_BUILD: "", CPPFLAGS_FOR_BUILD: "", LDFLAGS_FOR_BUILD: ""
    $"CC_($rs)": "cc-build", $"CXX_($rs)": "c++-build", $"PKG_CONFIG_($rs)": $"($dir)/pkg-config"}
}

# sources arrive unpacked (nix/sources.nix). cp -p: the store's uniform mtimes keep generated
# files "newer" than their inputs for make
def --env unpack [a: record, src: path, njobs: int]: nothing -> nothing {
  note unpack $a.src
  ^cp -rp $"($a.src)/." $src
  ^chmod -R u+w $src
  cd $src
  # -F0: a hunk whose context does not match is an error, not applied somewhere similar
  for p in $a.patches { note patch $p; ^patch -p1 -F0 -i $p }
  fix-shebangs . $njobs
}

# tests derivation: the kept source+build tree back at the same absolute paths, so configured
# paths inside it stay valid
def --env restore [from_tree: string, src: path]: nothing -> nothing {
  note restore $from_tree
  for d in [source build] { ^cp -a $"($from_tree)/($d)" $env.NIX_BUILD_TOP }
  ^chmod -R u+w $"($env.NIX_BUILD_TOP)/source" $"($env.NIX_BUILD_TOP)/build"
  cd $src
}

export def --env main [
  systems: record # build system name -> its OPTIONS table, from the generated script
  --from-tree: string = ""  # tests derivation: restore the package's tree instead of unpacking
]: nothing -> nothing {
  let a = (attrs)
  let spec = ($systems | transpose bs table | reduce -f $a.spec {|it, acc| $acc | upsert $it.bs (merge-options $it.bs $it.table ($acc | get -o $it.bs | default {})) })
  # the build installs outside the store, finish moves it (docs/design.md, Relocatable). In the
  # tests derivation $out is the built package and our own output just the log
  let out = (if $from_tree == "" { $"($env.NIX_BUILD_TOP)/prefix" } else { $a.package })
  $env.PKGS_RESULT = $a.outputs.out
  # 0 is nix for "all of them"
  let njobs = ($env.NIX_BUILD_CORES? | default "0" | into int | if $in > 0 { $in } else { sys cpu | length })
  let deps = (dep-closure $a.dependencies)
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
  $env.PKGS_CTX = {spec: $spec, out: $out, dest: $a.outputs.out, deps: $deps, roots: ($env.JIG_STORE_ROOTS | split row " "), njobs: $njobs, src: $env.PWD
    build: $build, platform: $plat, testsRun: $tests_run, cache: $cache}
}
