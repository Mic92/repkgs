# Everything after the last phase, in the order `main` lists it.
use core.nu *
use implant.nu
use launchers.nu

export def main [
  --keep-tree  # tests.separate: save source+build tree for the tests derivation
]: nothing -> nothing {
  let c = (ctx)
  install-map $c
  if $keep_tree { save-tree (attrs).outputs.tree $c.njobs }
  if not ($c.out | path exists) { error make {msg: "nothing was installed into $out"} }
  for b in (bins $c) {
    if not ($"($c.out)/bin/($b)" | path exists) { error make {msg: $"bin/($b) missing in output"} }
  }
  prune $c.out
  layout-check $c.out
  # installed copies of source scripts carry the build env's path from prepare: not a dependency
  fix-env-shebangs $c.out $c.njobs --undo
  mkdir (attrs).outputs.debug
  if $c.platform.binfmt == "elf" { relocate-elf $c }
  version-check $c
  write-exports $c
  cache-summary
}

# tests derivation output: a result marker. The package itself is untouched
export def tests []: nothing -> nothing {
  mkdir $env.PKGS_RESULT
  {package: (ctx).out, passed: true} | to json | save $"($env.PKGS_RESULT)/result.json"
  note tests passed
}

# spec.install {"<dest under $out>": glob | [globs]} relative to the source tree, a dest ending
# in / is a directory. spec.links {"<path>": "<target>"}
def install-map [c: record]: nothing -> nothing {
  for e in ($c.spec.install? | default {} | transpose dest from) {
    let to = $"($c.out)/($e.dest)"
    let from = ($e.from | each {|g| files --any $g } | flatten)
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

# source and build tree, mtimes kept so the tests derivation rebuilds nothing
def save-tree [tree: path, njobs: int]: nothing -> nothing {
  mkdir $tree
  cd $env.NIX_BUILD_TOP
  x bsdtar -c --zstd --options $"zstd:threads=($njobs)" -f $"($tree)/tree.tar.zst" source build
}

# `bin`, defaulting to the package's name when bin/<name> got installed
def bins [c: record]: nothing -> list<string> {
  $c.spec.bin? | default (if ($"($c.out)/bin/($c.spec.name)" | path exists) { [$c.spec.name] } else { [] })
}

def --wrapped find-files [out: path, ...tests: string]: nothing -> list<string> { ^find $out -type f ...$tests | lines }

# docs nobody reads from a store path, files with absolute paths or timestamps in them.
# Installed precompiled headers are an error
export def prune [out: path]: nothing -> nothing {
  for d in [share/doc share/info share/gtk-doc] { rm -rf $"($out)/($d)" }
  let junk = (find-files $out '(' -name '*.la' -o -name perllocal.pod -o -name .packlist -o -path '*/lib/charset.alias' ')')
  if ($junk | is-not-empty) { rm ...$junk }
  let gz = (find-files $out -path '*/share/man/*.gz')
  if ($gz | is-not-empty) { x gzip -d ...$gz }
  let pch = (find-files $out '(' -name '*.pch' -o -name '*.gch' ')')
  if ($pch | is-not-empty) { error make {msg: $"precompiled headers in output do not relocate: ($pch | first 3 | str join ' ')"} }
}

# lib/ and bin/ only, symlinks relative or made so, none dangling
export def layout-check [out: path]: nothing -> nothing {
  for d in [lib64 sbin] {
    if ($"($out)/($d)" | path exists) { error make {msg: $"($d)/ in output: configure with --libdir/--sbindir so it installs into lib/ and bin/"} }
  }
  for l in (^find $out -type l -printf '%p\t%l\n' | lines | split column "\t" link target) {
    let rel = ($l.link | path relative-to $out)
    if ($l.target | str starts-with $"($out)/") {
      ^ln -sfn (relative-link $rel ($l.target | path relative-to $out)) $l.link
    } else if ($l.target | str starts-with "/") {
      error make {msg: $"symlink ($rel) -> ($l.target) is absolute: outputs relocate, link relative"}
    }
    if not ($l.link | path exists) { error make {msg: $"symlink ($rel) -> ($l.target) dangles"} }
  }
}

# "lib/a.so" to "lib/b.so": "b.so", "bin/x" to "lib/y.so": "../lib/y.so"
def relative-link [from: string, to: string]: nothing -> string {
  let f = ($from | path split | drop 1)
  let t = ($to | path split)
  let common = ($f | zip $t | take while { $in.0 == $in.1 } | length)
  $f | skip $common | each { ".." } | append ($t | skip $common) | path join
}

# prebuilt `true` implants interp + stub, "ldso" stays byte-identical behind a launcher.
# --deny: a cross output must not mention build-machine packages
def relocate-elf [c: record]: nothing -> nothing {
  let prebuilt = ($c.spec.prebuilt? | default false)
  if $c.spec.debug { split-debug $c.out (attrs).outputs.debug $c.njobs }
  if $prebuilt == true { implant $c }
  launchers $c
  let a = (attrs)
  let deny = (if $c.platform.cross { $a.buildDependencies | where { $in not-in $a.dependencies } | each { [--deny $in] } | flatten } else { [] })
  if $prebuilt != "ldso" { x reloc-fixup $c.out ...$deny }
}

# DWARF -> `debug` under lib/debug/.build-id/, .symtab stays. A build-id means our linker made
# it, so no DWARF there is a build that strips: an error. No build-id: upstream binary, left alone
export def split-debug [out: path, debug: path, njobs: int]: nothing -> nothing {
  strip-archives $out
  let elfs = (elf-table $out $njobs)
  let stripped = ($elfs | where id != null and dwarf == false)
  if ($stripped | is-not-empty) {
    error make {msg: $"debug: linked here but no DWARF: ($stripped.file | first 3 | path relative-to $out | str join ' '). The build strips or drops -g. Fix that, or debug = false"}
  }
  let foreign = ($elfs | where id == null)
  if ($foreign | is-not-empty) {
    note debug $"($foreign | length) ELF files without build-id left as they are \(($foreign.file | first 2 | path basename | str join ' ')…)"
  }
  let ours = ($elfs | where id != null)
  if ($ours | is-empty) { return }
  ^chmod u+w ...$ours.file
  # one build-id twice is one binary installed twice: one .debug serves both
  $ours | group-by id --to-table | par-each --threads $njobs {|g|
    let dbg = $"($debug)/lib/debug/.build-id/($g.id | str substring 0..<2)/($g.id | str substring 2..).debug"
    mkdir ($dbg | path dirname)
    ^llvm-objcopy --only-keep-debug $g.items.0.file $dbg
    for f in $g.items.file { ^llvm-objcopy --strip-debug $f }
  } | ignore
  note debug $"($ours.id | uniq | length) files, (du $debug | get 0.apparent)"
}

# objcopy fails on archives with non-object members (LTO bitcode, lib.rmeta): those keep DWARF
def strip-archives [out: path]: nothing -> nothing {
  let archives = (find-files $out '(' -name '*.a' -o -name '*.o' ')')
  if ($archives | is-empty) { return }
  ^chmod u+w ...$archives
  for f in $archives {
    if (^llvm-objcopy --strip-debug $f | complete).exit_code != 0 { note debug $"DWARF left in ($f | path relative-to $out)" }
  }
}

# build-id and .debug_info presence per ELF, readelf batched and split at its "File:" headers
def elf-table [out: path, njobs: int]: nothing -> table<file: string, id: any, dwarf: bool> {
  find-files $out -size +3k '!' -name '*.[ao]' '!' -name '*.rlib'
  | where { is-elf $in }
  | chunks 64 | par-each --threads $njobs {|batch|
    let text = (^llvm-readelf -S -n ...$batch)
    let per_file = (if ($batch | length) == 1 { [$"($batch.0)\n($text)"] } else { $"\n($text)" | split row "\nFile: " | skip 1 })
    $per_file | each {|t|
      {file: ($t | lines | first), id: ($t | parse -r 'Build ID: ([0-9a-f]+)' | get -o capture0.0), dwarf: ($t | str contains ".debug_info")}
    }
  } | flatten
}

# tests.version: a command whose output must contain the upstream version ("-V", "ghc-pkg
# --numeric-version", true = "--version"), its first word picks the binary if bin/ has it.
# tests.relocated reruns it from a moved copy with env -i. Both run under dlaudit: a dlopen
# that finds nothing is a missing dependency
def version-check [c: record]: nothing -> nothing {
  let bins = (bins $c)
  let line = ($c.spec.tests?.version? | default ($bins | is-not-empty))
  if $line == false or ($c.platform.cross and not $c.testsRun) { return }
  let words = (if $line == true { [--version] } else { $line | split row " " })
  let cmd = (if $words.0 in $bins { $words } else { $bins | first 1 | append $words })
  let want = ($c.spec.version | str replace -r '-r[0-9]+$' "")
  let audit_out = $"($env.NIX_BUILD_TOP)/dlaudit.txt"
  # via qemu's -E when emulated. The audit libc needs surplus static TLS (librustc_driver),
  # taken from every thread's stack: 64K, tokio workers have 2M
  let audit = ([$"LD_AUDIT=($c.platform.dlaudit)" $"DLAUDIT_OUT=($audit_out)" "GLIBC_TUNABLES=glibc.rtld.optional_static_tls=0x10000"]
    | where { $c.platform.dlaudit != "" }
    | each {|e| if ($c.platform.emulator | is-empty) { [$e] } else { [-E $e] } } | flatten)
  let run = {|root: string|
    cd /
    rm -f $audit_out
    # empty environment but for HOME, which any real session has (rebar3 crashes without).
    # bzip2 --version goes on to compress stdin: stdout can be binary
    let r = (^env -i $"HOME=($env.NIX_BUILD_TOP)" ...($c.platform.emulator) ...$audit $"($root)/bin/($cmd.0)" ...($cmd | skip 1) | complete)
    if $r.exit_code != 0 or not ($"($r.stdout)($r.stderr)" | str contains $want) {
      error make {msg: $"version check: `($cmd | str join ' ')` did not print ($want) \(exit ($r.exit_code))\n($r.stdout)($r.stderr)"}
    }
    let missed = (if ($audit_out | path exists) { open --raw $audit_out | lines | uniq | where { $in not-in ($c.spec.tests?.dlopen? | default []) } } else { [] })
    if ($missed | is-not-empty) {
      error make {msg: $"version check: `($cmd | str join ' ')` dlopens ($missed | str join ', '), not in the closure \(a missing dependency, or tests.dlopen = [names] if optional)"}
    }
  }
  do $run $c.out
  let relocated = ($c.spec.tests?.relocated? == true)
  if $relocated {
    let root = $"($env.NIX_BUILD_TOP)/relocated"
    # beside the copy: every store root the build saw, and launch (bin/ launchers link to it)
    mkdir $root
    for d in ($c.roots ++ [($c.platform.launch | path dirname -n 2)] | uniq) { ^ln -s $d $root }
    ^cp -r $c.out $root
    do $run $"($root)/($c.out | path basename)"
    rm -rf $root
  }
  note version $"($cmd | str join ' ') -> ($want)(if $relocated { ', relocated' })"
}

# exports.json for dependents (core.nu exports-of). exports = false: nothing to link against
def write-exports [c: record]: nothing -> nothing {
  let none = {includeDirs: [], libDirs: [], libs: [], pkgconfigDirs: [], aclocalDirs: []}
  let own = (if $c.spec.exports? == false { $none } else { $c.spec.exports? | default {} })
  let exports = (exports-of $c.out | merge $own | upsert name $c.spec.name)
  $exports | to json | save -f $"($c.out)/exports.json"
  note exports ($exports | to json -r)
}

# "jig: cc cached=812/855 (95%) compiled=40 …" from $JIG_LOG (tool, outcome, subject, ms per run)
def cache-summary []: nothing -> nothing {
  if not ($env.JIG_LOG | path exists) { return }
  # `query` (cc -v, -dM, -print-*) is not a build step and stays out of the counts
  let runs = (open --raw $env.JIG_LOG | from tsv --noheaders | rename tool outcome subject | where outcome != query)
  let tools = ($runs | group-by tool --to-table)
  let parts = ($tools | each {|t|
    let counts = ($t.items.outcome | uniq -c)
    let total = ($t.items | length)
    let cached = ($counts | where value == cached | get count | append 0 | first)
    let rest = ($counts | where value != cached | each { $"($in.value)=($in.count)" })
    [$t.tool $"cached=($cached)/($total) \(($cached * 100 // $total)%)" ...$rest] | str join " "
  })
  if ($parts | is-not-empty) { note jig ($parts | str join ", ") }
  # only cc subjects say why ("<source> new-key|inputs-changed:<path>|object-gone")
  for t in $tools {
    let reasons = ($t.items | where outcome starts-with compiled and subject =~ " " | get subject | each { split row " " | last })
    if ($reasons | is-empty) { continue }
    note $"($t.tool)-misses" ($reasons | each { split row ":" | first } | uniq -c | each { $"($in.value)=($in.count)" } | str join " ")
    let stale = ($reasons | where $it starts-with "inputs-changed:" | str substring 15.. | uniq -c | sort-by -r count | first 5 | each { $"($in.value) ×($in.count)" })
    if ($stale | is-not-empty) { note $"($t.tool)-stale" ($stale | str join ", ") }
  }
  # a sample of what jig would not cache
  if ($env.JIG_LOG_ARGS | path exists) {
    for l in (open --raw $env.JIG_LOG_ARGS | lines | shuffle | first 5) { note uncached ($l | str substring 0..300) }
  }
}
