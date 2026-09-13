# Everything after the last phase, in the order `main` lists it.
use core.nu *
use implant.nu
use launchers.nu

# --env: the cd must outlive the call
export def --env main [
  --keep-tree  # tests.separate: save source+build tree for the tests derivation
]: nothing -> nothing {
  let c = (ctx)
  install-map $c
  if $keep_tree { save-tree (attrs).outputs.tree $c.njobs }
  if not ($c.out | path exists) { error make {msg: "nothing was installed into $out"} }
  for b in (bins $c) {
    if not ($"($c.out)/bin/($b)" | path exists) { error make {msg: $"bin/($b) missing in output"} }
  }
  let inv = (prune $c.out (inventory $c.out))
  layout-check $c.out
  # installed copies of source scripts carry the build env's path from prepare: not a dependency
  fix-env-shebangs $c.out $c.njobs --undo
  mkdir (attrs).outputs.debug
  if $c.platform.binfmt == "elf" { relocate-elf $c $inv }
  write-exports $c.out $c.spec $c.deps
  note exports (open --raw $"($c.out)/exports.json" | from json | to json -r)
  cd $env.NIX_BUILD_TOP
  to-store $c.out $c.dest $inv
  version-check ($c | update out $c.dest)
  cache-summary
}

# prefix -> ${pcfiledir}/../..
def relativize-pc [prefix: string, pcs: list<string>]: nothing -> nothing {
  if ($pcs | is-empty) { return }
  for f in (^grep -lF $prefix ...$pcs | complete | get stdout | lines) {
    let up = ($f | path dirname | path relative-to $prefix | path split | each { ".." } | str join "/")
    open --raw $f | str replace -a $prefix $"${pcfiledir}/($up)" | save -f $f
  }
}

# foo-config style sh scripts: prefix from $0
def relativize-scripts [prefix: string]: nothing -> nothing {
  # listed afresh: launchers renamed bin/x to bin/.x
  let scripts = (if ($"($prefix)/bin" | path exists) { ^find $"($prefix)/bin" -maxdepth 1 -type f | lines } else { [] })
  if ($scripts | is-empty) { return }
  const FROM_0 = 'prefix=$(cd "$(dirname "$0")/.." && pwd -P)'
  for f in (^grep -lF $prefix ...$scripts | complete | get stdout | lines) {
    let lines = (open --raw $f | lines)
    if ($lines.0 !~ '^#!.*sh$') or not ($lines | any { ($in | str replace -ar `["']` "") == $"prefix=($prefix)" }) { continue }
    ($lines
      | each {|l| if ($l | str replace -ar `["']` "") == $"prefix=($prefix)" { $FROM_0 } else { $l | str replace -a $prefix '${prefix}' } }
      | str join "\n" | save -f $f)
    note script $"bin/($f | path basename): prefix from $0"
  }
}

# prefix -> store, anything still naming the prefix is an error
export def to-store [prefix: string, dest: string, inv: table]: nothing -> nothing {
  relativize-pc $prefix ($inv | where type == f and rel =~ '\.pc$' | get path)
  relativize-scripts $prefix
  relativize-links $prefix $dest
  let hits = (^grep -rlF $prefix $prefix | complete | get stdout | lines)
  if ($hits | is-not-empty) {
    let detail = ($hits | first 10 | each {|f|
      let found = (^strings -n ($prefix | str length) $f | lines | where { $in | str contains $prefix } | uniq | first 3
        | each { str replace -a $prefix '$out' | str substring 0..120 })
      $"  ($f | path relative-to $prefix): ($found | str join ', ')"
    })
    let more = if ($hits | length) > 10 { $"
  ... and (($hits | length) - 10) more" } else { "" }
    error make {msg: $"not relocatable: ($hits | length) files name the install prefix \(shown as $out). Make the path relative to the file \(reloc.h RELOC, ${pcfiledir}, $ORIGIN) or configure it away:
($detail | str join "
")($more)"}
  }
  ^chmod -R u+w $prefix
  ^mv $prefix $dest
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

# the tree walked once, later steps filter it (toybox find has no %y)
export def inventory [out: path]: nothing -> table {
  let n = (($out | str length) + 1)
  [f l d] | each {|t|
    ^find $out -mindepth 1 -type $t -printf '%s\t%p\t%l\n' | from tsv --noheaders --no-infer
    | rename size path target | insert type $t
  } | flatten | update size { into int } | insert rel { $in.path | str substring $n.. }
}

# docs, junk with absolute paths or timestamps. Returns the inventory minus what it removed
export def prune [out: path, inv: table]: nothing -> table {
  const DOCS = [share/doc/ share/info/ share/gtk-doc/]
  for d in $DOCS { rm -rf $"($out)/($d)" }
  let inv = ($inv | where {|e| not ($DOCS | any {|d| $"($e.rel)/" | str starts-with $d }) })
  let files = ($inv | where type == f)
  let junk = ($files | where { $in.rel =~ '(\.la|/perllocal\.pod|/\.packlist|^lib/charset\.alias)$' })
  if ($junk | is-not-empty) { rm ...$junk.path }
  let gz = ($files | where rel =~ '^share/man/.*\.gz$')
  if ($gz | is-not-empty) { x gzip -d ...$gz.path }
  let pch = ($files | where rel =~ '\.[pg]ch$')
  if ($pch | is-not-empty) { error make {msg: $"precompiled headers in output do not relocate: ($pch.rel | first 3 | str join ' ')"} }
  $inv | where rel not-in $junk.rel | update rel {|e| if $e.rel in $gz.rel { $e.rel | str replace -r '\.gz$' "" } else { $e.rel } } | update path {|e| $"($out)/($e.rel)" }
}

# lib/ and bin/ only
export def layout-check [out: path]: nothing -> nothing {
  for d in [lib64 sbin] {
    if ($"($out)/($d)" | path exists) { error make {msg: $"($d)/ in output: configure with --libdir/--sbindir so it installs into lib/ and bin/"} }
  }
}

# absolute links become relative to their place in the store, none may dangle
def relativize-links [prefix: string, dest: string]: nothing -> nothing {
  # listed afresh: launchers added links
  for l in (^find $prefix -type l -printf '%P\t%l\n' | from tsv --noheaders --no-infer | rename rel target) {
    # where it points once the tree is at dest
    let target = (if ($l.target | str starts-with $"($prefix)/") { $"($dest)/($l.target | path relative-to $prefix)" } else { $"($dest)/($l.rel)" | path dirname | path join $l.target | path expand -n })
    if not ($target | str starts-with $"($env.NIX_STORE)/") { error make {msg: $"symlink ($l.rel) -> ($l.target) leaves the store"} }
    if ($l.target | str starts-with "/") { ^ln -sfn (relative-link $"($dest)/($l.rel)" $target) $"($prefix)/($l.rel)" }
    let here = (if ($target | str starts-with $"($dest)/") { $"($prefix)/($target | path relative-to $dest)" } else { $target })
    if not ($here | path exists -n) { error make {msg: $"symlink ($l.rel) -> ($l.target) dangles"} }
  }
}

# link at `from` pointing to `to`, both absolute: the relative target
def relative-link [from: string, to: string]: nothing -> string {
  let f = ($from | path split | drop 1 | skip 1)
  let t = ($to | path split | skip 1)
  let common = ($f | zip $t | take while { $in.0 == $in.1 } | length)
  $f | skip $common | each { ".." } | append ($t | skip $common) | path join
}

# prebuilt `true` implants interp + stub, "ldso" stays byte-identical behind a launcher.
# --deny: a cross output must not mention build-machine packages
def relocate-elf [c: record, inv: table]: nothing -> nothing {
  let prebuilt = ($c.spec.prebuilt? | default false)
  if $c.spec.debug { split-debug $c.out (attrs).outputs.debug $c.njobs ($inv | where type == f) }
  if $prebuilt == true { implant $c }
  launchers $c
  let a = (attrs)
  let deny = (if $c.platform.cross { $a.buildDependencies | where { $in not-in $a.dependencies } | each { [--deny $in] } | flatten } else { [] })
  if $prebuilt != "ldso" { x reloc-fixup $c.out --dest $c.dest ...$deny }
}

# DWARF -> `debug` under lib/debug/.build-id/, .symtab and a .gnu_debuglink stay. Only for what
# jig linked (its package note): no DWARF and no debuglink there means the build strips, an error.
# Upstream binaries and ours copied from a dependency (already split) are left alone
export def split-debug [out: path, debug: path, njobs: int, files: table]: nothing -> nothing {
  strip-archives $out ($files | where rel =~ '\.[ao]$')
  let elfs = (elf-table ($files | where size > 3072 and rel !~ '\.(a|o|rlib)$' | get path) $njobs)
  let stripped = ($elfs | where {|e| $e.ours and not $e.dwarf and not $e.split })
  if ($stripped | is-not-empty) {
    error make {msg: $"debug: linked here but no DWARF: ($stripped.file | first 3 | path relative-to $out | str join ' '). The build strips or drops -g. Fix that, or debug = false"}
  }
  let foreign = ($elfs | where {|e| not $e.ours or $e.split })
  if ($foreign | is-not-empty) {
    note debug $"($foreign | length) ELF files not linked here left as they are \(($foreign.file | first 2 | path basename | str join ' ')…)"
  }
  let ours = ($elfs | where {|e| $e.ours and not $e.split })
  if ($ours | is-empty) { return }
  ^chmod u+w ...$ours.file
  # one build-id twice is one binary installed twice: one .debug serves both
  $ours | group-by id --to-table | par-each --threads $njobs {|g|
    let dbg = $"($debug)/lib/debug/.build-id/($g.id | str substring 0..<2)/($g.id | str substring 2..).debug"
    mkdir ($dbg | path dirname)
    ^llvm-objcopy --only-keep-debug $g.items.0.file $dbg
    for f in $g.items.file { ^llvm-objcopy --strip-debug $"--add-gnu-debuglink=($dbg)" $f }
  } | ignore
  note debug $"($ours.id | uniq | length) files, (du $debug | get 0.apparent)"
}

# objcopy fails on archives with non-object members (LTO bitcode, lib.rmeta): those keep DWARF
def strip-archives [out: path, archives: table]: nothing -> nothing {
  if ($archives | is-empty) { return }
  ^chmod u+w ...$archives.path
  for f in $archives {
    if (^llvm-objcopy --strip-debug $f.path | complete).exit_code != 0 { note debug $"DWARF left in ($f.rel)" }
  }
}

# build-id, .debug_info and .gnu_debuglink presence per ELF, readelf batched and split at its "File:" headers
def elf-table [candidates: list<string>, njobs: int]: nothing -> table<file: string, id: any, ours: bool, dwarf: bool, split: bool> {
  $candidates
  | where { is-elf $in }
  | chunks 64 | par-each --threads $njobs {|batch|
    let text = (^llvm-readelf -S -n ...$batch)
    let per_file = (if ($batch | length) == 1 { [$"($batch.0)\n($text)"] } else { $"\n($text)" | split row "\nFile: " | skip 1 })
    $per_file | each {|t|
      # 0xcafe1a7e: the FDO package note jig links in
      {file: ($t | lines | first), id: ($t | parse -r 'Build ID: ([0-9a-f]+)' | get -o capture0.0), ours: ($t | str contains "0xcafe1a7e"), dwarf: ($t | str contains ".debug_info"), split: ($t | str contains ".gnu_debuglink")}
    }
  } | flatten
}

# tests.version: a command whose output must contain the pinned version (true = --version), its
# first word picks the binary. Run in place and from a copy of the closure under another root
# (env -i), where an absolute store path would show. Under dlaudit: a failed dlopen is an error
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
  # beside the copy: every store root the build saw, and launch (bin/ launchers link to it)
  let root = $"($env.NIX_BUILD_TOP)/relocated"
  mkdir $root
  for d in ($c.roots ++ [($c.platform.launch | path dirname -n 2)] | uniq) { ^ln -s $d $root }
  ^cp -r $c.out $root
  do $run $"($root)/($c.out | path basename)"
  rm -rf $root
  note version $"($cmd | str join ' ') -> ($want)"
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
