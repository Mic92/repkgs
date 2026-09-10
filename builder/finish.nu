# Everything after the last verb: check the output, strip + split debug info, generate launchers,
# reloc-fixup the tree, version/relocation check, write exports.json, print the cache summary.
use core.nu *
use implant.nu
use launchers.nu

# split DWARF to lib/debug, keep .symtab (§4 profiling-friendly). Only files with debug info:
# upstream .so files out of binary wheels have none, and llvm-objcopy crashes on those that
# auto-formatelf relaid (program headers moved to the end)
def split-debug [c: record]: nothing -> nothing {
  let elfs = (glob $"($c.out)/{bin,lib,libexec}/**/*" --exclude [**/lib/debug/**]
    | where { ($in | path type) == "file" and (is-elf $in) and (^llvm-readelf -S $in | str contains ".debug_info") })
  if ($elfs | is-empty) { return }
  mkdir $"($c.out)/lib/debug"
  $elfs | par-each --threads $c.njobs {|f|
    let dbg = $"($c.out)/lib/debug/($f | path basename).debug"
    ^chmod u+w $f
    x llvm-objcopy --only-keep-debug $f $dbg
    x llvm-objcopy --strip-debug $"--add-gnu-debuglink=($dbg)" $f
  } | ignore
}


# `bin`, defaulting to the package's name when bin/<name> got installed
def bins [c: record]: nothing -> list<string> {
  $c.spec.bin? | default (if ($"($c.out)/bin/($c.spec.name)" | path exists) { [$c.spec.name] } else { [] })
}

# `tests.version`: a command line whose output must contain spec.version (upstream part, "-rN"
# revision stripped): "-V", "version", "ghc-pkg --numeric-version". The first word picks the
# binary when bin/ has it, else the words go to the first `bin`. true (the default with a bin)
# is "--version". `tests.relocated` reruns it from a copy of `out` under a scratch prefix with
# the sibling store paths symlinked beside it, cwd / and env -i: the §3 property, per package
def version-check [c: record]: nothing -> nothing {
  let bins = (bins $c)
  let line = ($c.spec.tests?.version? | default ($bins | is-not-empty))
  if $line == false or ($c.platform.cross and not $c.testsRun) { return }
  let words = (if $line == true { [--version] } else { $line | split row " " })
  let cmd = (if $words.0 in $bins { $words } else { $bins | first 1 | append $words })
  let want = ($c.spec.version | str replace -r '-r[0-9]+$' "")
  let run = {|root: string|
    cd /
    # bzip2 --version goes on to compress stdin: stdout can be binary
    let r = (^env -i ...($c.platform.emulator) $"($root)/bin/($cmd.0)" ...($cmd | skip 1) | complete)
    if $r.exit_code != 0 or not ($"($r.stdout)($r.stderr)" | str contains $want) {
      error make {msg: $"version check: `($cmd | str join ' ')` did not print ($want) \(exit ($r.exit_code))\n($r.stdout)($r.stderr)"}
    }
  }
  do $run $c.out
  let relocated = ($c.spec.tests?.relocated? == true)
  if $relocated {
    let root = $"($env.NIX_BUILD_TOP)/relocated"
    let a = (attrs)
    # beside the copy: dependencies, the toolchain roots (libc), and launch (bin/ launchers link to it)
    let siblings = (dep-closure $a.dependencies | get root) ++ ($env.JIG_STORE_ROOTS | split row " ") ++ [($c.platform.launch | path dirname -n 2)]
    mkdir $root
    for d in ($siblings | uniq) { ^ln -s $d $root }
    ^cp -r $c.out $root
    do $run $"($root)/($c.out | path basename)"
    rm -rf $root
  }
  note version $"($cmd | str join ' ') -> ($want)(if $relocated { ', relocated' })"
}

# jig's outcomes summed up per tool: "jig: cc cached=812/855 (95%) compiled=40 linked=3, rustc cached=…".
# go's cache program writes its own counted line
def cache-summary []: nothing -> nothing {
  if not ($env.JIG_LOG | path exists) { return }
  let ls = (open --raw $env.JIG_LOG | lines)
  let go = ($ls | where { str starts-with "go " } | each { str substring 3.. })
  let tools = ($ls | where { $in !~ "^go " } | each { split row " " | first } | uniq -c
    | each {|k| let p = ($k.value | parse -r '^(?:(?<tool>rustc)-)?(?<kind>.*)$' | first); {tool: (if ($p.tool | is-empty) { "cc" } else { $p.tool }), kind: $p.kind, count: $k.count} }
    | group-by tool --to-table
    | each {|t|
      let total = ($t.items.count | math sum)
      let cached = ($t.items | where kind == cached | get count | append 0 | math sum)
      let rest = ($t.items | where kind != cached | each { $"($in.kind)=($in.count)" })
      [$t.tool $"cached=($cached)/($total) \(($cached * 100 // $total)%)" ...$rest] | str join " "
    })
  let parts = ($tools ++ ($go | each { $"go ($in)" }))
  if ($parts | is-not-empty) { note jig ($parts | str join ", ") }
  # a few of the command lines jig would not cache, to spot shapes worth teaching it
  if ($env.JIG_LOG_ARGS | path exists) {
    for l in (open --raw $env.JIG_LOG_ARGS | lines | shuffle | first 5) { note uncached ($l | str substring 0..300) }
  }
}

# spec.install {"<dest under $out>": "<glob in the source tree>" | [globs]}: copied after the steps
# ran, a dest ending in / is a directory the matches go into. spec.links {"<path>": "<target>"}
# `install` sources are globs relative to the source tree (where finish runs)
def install-map [c: record]: nothing -> nothing {
  for e in ($c.spec.install? | default {} | transpose dest from) {
    let to = $"($c.out)/($e.dest)"
    let from = ($e.from | each {|g| glob $g } | flatten)
    if ($from | is-empty) { error make {msg: $"install ($e.dest): nothing matches ($e.from)"} }
    if ($e.dest | str ends-with "/") or ($from | length) > 1 {
      mkdir $to
      for f in $from { ^cp -rp $f $to }
    } else {
      mkdir ($to | path dirname)
      ^cp -rp $from.0 $to
    }
  }
  for e in ($c.spec.links? | default {} | transpose path target) {
    mkdir ($"($c.out)/($e.path)" | path dirname)
    ^ln -sfn $e.target $"($c.out)/($e.path)"
  }
}

export def main [
  --keep-tree  # tests.separate: save source+build tree for the tests derivation
]: nothing -> nothing {
  let c = (ctx)
  install-map $c
  if $keep_tree {
    let tree = (attrs).outputs.tree
    mkdir $tree
    # mtimes preserved so make/ninja consider everything up to date in the tests derivation
    cd $env.NIX_BUILD_TOP
    x bsdtar -c --zstd --options $"zstd:threads=($c.njobs)" -f $"($tree)/tree.tar.zst" source build
  }
  if not ($c.out | path exists) { error make {msg: "nothing was installed into $out"} }
  for b in (bins $c) {
    if not ($"($c.out)/bin/($b)" | path exists) { error make {msg: $"bin/($b) missing in output"} }
  }
  for f in (glob $"($c.out)/**/*.la") { rm $f }
  # no separate doc outputs (yet): HTML/info docs are never read from a store path, man pages stay
  for d in [share/doc share/info share/gtk-doc] { rm -rf $"($c.out)/($d)" }
  # precompiled headers pin absolute header paths: fine in a build tree, broken once installed
  let pch = (glob $"($c.out)/**/*.{pch,gch}")
  if ($pch | is-not-empty) { error make {msg: $"precompiled headers in output do not relocate: ($pch | first 3 | str join ' ')"} }
  # gzip headers carry an mtime and file name: ship man and info pages uncompressed (the store compresses)
  let gz = (glob $"($c.out)/share/{man,info}/**/*.gz")
  if ($gz | is-not-empty) { x gzip -d ...$gz }
  # installed copies of source scripts carry the build env's path from prepare: not a dependency
  fix-env-shebangs $c.out $c.njobs --undo
  let prebuilt = ($c.spec.prebuilt? | default false)
  # upstream binaries: no debug split. `true` implants interp + stub so they relocate like ours,
  # "ldso" leaves them byte-identical behind an ld.so launcher (builder/launchers.nu)
  if $prebuilt == false { split-debug $c }
  if $prebuilt == true { implant $c }
  launchers $c
  # RUNPATH/PT_INTERP -> $ORIGIN-relative, in place (pkgs/ji/jig/src/fixup_mode.cc)
  if $prebuilt != "ldso" { x reloc-fixup $c.out }
  version-check $c
  # exports = false: a toolchain or application whose lib/ is its own business, nothing to link
  let own = (if $c.spec.exports? == false { {includeDirs: [], libDirs: [], libs: [], pkgconfigDirs: [], aclocalDirs: []} } else { $c.spec.exports? | default {} })
  let exports = (exports-of $c.out | merge $own | upsert name $c.spec.name)
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
