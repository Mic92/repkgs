# Everything after the last verb: check the output, strip + split debug info, generate launchers,
# reloc-fixup the tree, version/relocation check, write exports.json, print the cache summary.
use core.nu *
use launchers.nu

# split DWARF to lib/debug, keep .symtab (§4 profiling-friendly)
def split-debug [c: record<spec: record, out: string, deps: list<record>, njobs: int, src: string, build: string, platform: record, testsRun: bool, cache: bool>]: nothing -> nothing {
  let elfs = (glob $"($c.out)/{bin,lib,libexec}/**/*" --exclude [**/lib/debug/**]
    | where { ($in | path type) == "file" and (is-elf $in) })
  if ($elfs | is-empty) { return }
  mkdir $"($c.out)/lib/debug"
  $elfs | par-each --threads $c.njobs {|f|
    let dbg = $"($c.out)/lib/debug/($f | path basename).debug"
    ^chmod u+w $f
    x llvm-objcopy --only-keep-debug $f $dbg
    x llvm-objcopy --strip-debug $"--add-gnu-debuglink=($dbg)" $f
  } | ignore
}

# `tests.version` (default `"--version"` when `bin` is set, false to skip): bin/<first bin> <flag>
# must print spec.version (upstream part, "-rN" revision stripped). `tests.relocated = true` reruns
# it after copying `out` under a scratch prefix with sibling store paths symlinked beside it, from /
# with env -i: the §3 property, per package, for the cost of one cp.
def version-check [c: record<spec: record, out: string, deps: list<record>, njobs: int, src: string, build: string, platform: record, testsRun: bool, cache: bool>]: nothing -> nothing {
  let bins = ($c.spec.bin? | default [])
  let flag = ($c.spec.tests?.version? | default (if ($bins | is-empty) { false } else { "--version" }))
  if ($flag | describe) == "bool" or ($c.platform.cross and not $c.testsRun) { return }
  let want = ($c.spec.version | str replace -r '-r[0-9]+$' "")
  let run = {|bin: string|
    cd /
    let r = (^env -i ...($c.platform.emulator) $bin $flag | complete)
    if $r.exit_code != 0 or ($"($r.stdout)($r.stderr)" | find --no-highlight $want | is-empty) {
      error make {msg: $"version check: `($bin) ($flag)` did not print ($want) \(exit ($r.exit_code))\n($r.stdout)($r.stderr)"}
    }
  }
  do $run $"($c.out)/bin/($bins | first)"
  let relocated = ($c.spec.tests?.relocated? | default false)
  if $relocated {
    let root = $"($env.NIX_BUILD_TOP)/relocated"
    rm -rf $root
    mkdir $root
    let a = (attrs)
    let closure = (dep-closure ($a.dependencies ++ $a.runtimeDependencies) | get root) ++ ($env.JIG_STORE_ROOTS | split row " ")
    for d in ($closure | uniq | where { $in != $c.out }) { ^ln -s $d $"($root)/($d | path basename)" }
    ^cp -r $c.out $"($root)/($c.out | path basename)"
    do $run $"($root)/($c.out | path basename)/bin/($bins | first)"
    rm -rf $root
  }
  note version $"($bins | first) ($flag) -> ($want)(if $relocated { ', relocated' } else { '' })"
}

# compile-cache summary: "hit=812 miss-stored=3 plain=40 rs-hit=…"; gocacheprog reports its own line
def cache-summary []: nothing -> nothing {
  if not ($env.JIG_LOG | path exists) { return }
  let ls = (open --raw $env.JIG_LOG | lines)
  for l in ($ls | where { str starts-with "gocacheprog" }) { note cache $l }
  let kinds = ($ls | where { $in !~ "^gocacheprog" } | each { split row " " | first } | uniq -c)
  if ($kinds | is-not-empty) { note cache ($kinds | each { $"($in.value)=($in.count)" } | str join " ") }
  # a few of the command lines jig would not cache, to spot shapes worth teaching it
  if ($env.JIG_LOG_ARGS | path exists) {
    for l in (open --raw $env.JIG_LOG_ARGS | lines | shuffle | first 5) { note uncached ($l | str substring 0..300) }
  }
}

export def main [
  --keep-tree  # tests.separate: save source+build tree for the tests derivation
]: nothing -> nothing {
  let c = (ctx)
  if $keep_tree {
    let tree = (attrs).outputs.tree
    mkdir $tree
    # mtimes preserved so make/ninja consider everything up to date in the tests derivation
    cd $env.NIX_BUILD_TOP
    x bsdtar -c --zstd --options $"zstd:threads=($c.njobs)" -f $"($tree)/tree.tar.zst" source build
  }
  if not ($c.out | path exists) { error make {msg: "nothing was installed into $out"} }
  for b in ($c.spec.bin? | default []) {
    if not ($"($c.out)/bin/($b)" | path exists) { error make {msg: $"bin/($b) missing in output"} }
  }
  for f in (glob $"($c.out)/**/*.la") { rm $f }
  # gzip headers carry an mtime and file name: ship man and info pages uncompressed (the store compresses)
  for f in (glob $"($c.out)/share/{man,info}/**/*.gz") { x gzip -d $f }
  let prebuilt = ($c.spec.prebuilt? | default false)
  # upstream binaries stay byte-identical: their own $ORIGIN rpaths, no debug split, launchers instead
  if not $prebuilt { split-debug $c }
  launchers $c
  # RUNPATH/PT_INTERP -> $ORIGIN-relative, in place (pkgs/ji/jig/src/fixup_mode.cc)
  if not $prebuilt { x reloc-fixup $c.out }
  version-check $c
  let exports = (exports-of $c.out | merge ($c.spec.exports? | default {}) | upsert name $c.spec.name)
  $exports | to json | save -f $"($c.out)/exports.json"
  note exports ($exports | to json -r)
  cache-summary
}

# tests derivation output: a result marker. The package itself is untouched
export def tests []: nothing -> nothing {
  mkdir $env.PKGS_RESULT
  {package: (ctx).out, passed: true} | to json | save $"($env.PKGS_RESULT)/result.json"
  note tests passed
}
