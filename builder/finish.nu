# Everything after the last phase, in the order `main` lists it.
use core.nu *
use debug.nu [split-debug split-debug-macho strip-archives]
use implant.nu
use launchers.nu

# --env: the cd must outlive the call
export def --env main [
  --keep-tree  # tests.separate: save source+build tree for the tests derivation
]: nothing -> nothing {
  let c = (ctx)
  install-map $c
  if $keep_tree { save-tree (attrs).outputs.tree }
  if not ($c.out | path exists) { error make {msg: "nothing was installed into $out"} }
  for b in (bins $c) {
    if not ($"($c.out)/bin/($b)($c.platform.ext.exe)" | path exists) { error make {msg: $"bin/($b)($c.platform.ext.exe) missing in output"} }
  }
  let inv = (prune $c.out (inventory $c.out))
  layout-check $c.out
  # installed copies of source scripts carry the build env's path from prepare: not a dependency
  fix-shebangs $c.out $c.njobs --undo
  mkdir (attrs).outputs.debug
  relocate $c $inv
  write-exports $c.out $c.spec $c.platform $c.deps
  note exports (open --raw $"($c.out)/exports.json" | from json | to json -r)
  cd $env.NIX_BUILD_TOP
  to-store $c.out $c.dest $inv
  version-check ($c | update out $c.dest)
  cache-summary
}

# Rewrite the absolute prefix in `files` as `<var>/../..`, i.e. relative to the file itself:
# ${pcfiledir} for .pc files, ${CMAKE_CURRENT_LIST_DIR} for autoconf-substituted FooConfig.cmake
# (fftw), which is what cmake-generated ones use
def relativize-text [prefix: string, var: string, files: list<string>]: nothing -> nothing {
  if ($files | is-empty) { return }
  for f in (^grep -lF $prefix ...$files | complete | get stdout | lines) {
    let up = ($f | path dirname | path relative-to $prefix | path split | each { ".." } | str join "/")
    let text = (open --raw $f | str replace -a $prefix $"${($var)}/($up)")
    $text | save -f $f
  }
}

# documentation quoting the configured prefix has no relative form
def generic-man-prefix [prefix: string, pages: list<string>]: nothing -> nothing {
  if ($pages | is-empty) { return }
  let hits = (^grep -lF $prefix ...$pages | complete | get stdout | lines)
  for f in $hits {
    let text = (open --raw $f | str replace -a $prefix "/usr")
    $text | save -f $f
  }
  if ($hits | is-not-empty) { note man $"($hits | length) pages named the prefix, now /usr" }
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

def relativize-sonames [prefix: string, cmakes: list<string>]: nothing -> nothing {
  if ($cmakes | is-empty) { return }
  for f in (^grep -lF $"IMPORTED_SONAME" ...$cmakes | complete | get stdout | lines) {
    ^chmod u+w $f
    let re = (['(IMPORTED_SONAME_\w+ )"' $prefix '/[^"]*/([^/"]+)"'] | str join)
    let text = (open --raw $f | str replace -ar $re '${1}"@rpath/${2}"')
    $text | save -f $f
  }
}

# prefix -> store, anything still naming the prefix is an error
export def to-store [prefix: string, dest: string, inv: table]: nothing -> nothing {
  ^chmod -R u+w $prefix # some install -m 0444
  relativize-text $prefix pcfiledir ($inv | where type == f and rel =~ '\.pc$' | get path)
  relativize-text $prefix CMAKE_CURRENT_LIST_DIR ($inv | where type == f and rel =~ '\.cmake$' | get path)
  generic-man-prefix $prefix ($inv | where type == f and rel starts-with share/man/ | get path)
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
  ^mv $prefix $dest
}

# tests derivation output: a result marker. The package itself is untouched
export def tests []: nothing -> nothing {
  mkdir $env.PKGS_RESULT
  {package: (ctx).out, passed: true} | to json | save $"($env.PKGS_RESULT)/result.json"
  note tests passed
}

# spec.install {"<dest under $out>": glob | [globs]} relative to the source tree, a dest ending
# in / is a directory. spec.links {"<path>": "<target>"}, bin/ entries get the platform's exe suffix
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
    let exe = (if ($e.path | str starts-with "bin/") { $c.platform.ext.exe } else { "" })
    mkdir ($"($c.out)/($e.path)" | path dirname)
    ^ln -sfn $"($e.target)($exe)" $"($c.out)/($e.path)($exe)"
  }
}

# source and build tree as a plain directory: the store and binary caches compress and dedup
# files, a tarball would defeat both. The store sets every mtime to 1, and with all of them
# equal make has nothing to rebuild
def save-tree [tree: path]: nothing -> nothing {
  mkdir $tree
  cd $env.NIX_BUILD_TOP
  x cp -a source build $tree
}

# `bin`, defaulting to the package's name when bin/<name> got installed
def bins [c: record]: nothing -> list<string> {
  $c.spec.bin? | default (if ($"($c.out)/bin/($c.spec.name)($c.platform.ext.exe)" | path exists) { [$c.spec.name] } else { [] })
}

# the tree walked once, later steps filter it (toybox find has no %y)
export def inventory [out: path]: nothing -> table {
  let n = (($out | str length) + 1)
  [f l d] | each {|t|
    ^find $out -mindepth 1 -type $t -printf '%s\t%p\t%l\n' | from tsv --noheaders --no-infer
    | rename size path target | insert type $t
  } | flatten | update size { into int } | insert rel { $in.path | str substring $n.. }
}

# docs, junk with absolute paths or timestamps. Returns the inventory minus what it removed.
# x.dSYM is what `clang -g a.c -o x` leaves on Darwin. split-debug-macho makes its own
export def prune [out: path, inv: table]: nothing -> table {
  let dirs = ([share/doc share/info share/gtk-doc] ++ ($inv | where type == d and rel =~ '\.dSYM$' | get rel))
  for d in $dirs { rm -rf $"($out)/($d)" }
  let inv = ($inv | where {|e| not ($dirs | any {|d| $e.rel == $d or ($e.rel | str starts-with $"($d)/") }) })
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

# What the binaries of each format need before reloc-fixup. prebuilt `true` implants interp +
# stub, "ldso" stays byte-identical behind a launcher
def binaries-elf [c: record, inv: table]: nothing -> nothing {
  if $c.spec.debug { split-debug $c.out (attrs).outputs.debug $c.njobs ($inv | where type == f) }
  if $c.spec.prebuilt? == true { implant $c }
  launchers $c
}

# cmake records the install_name the project chose, reloc-fixup makes the dylib's own @rpath
def binaries-macho [c: record, inv: table]: nothing -> nothing {
  if $c.spec.debug { split-debug-macho $c.out (attrs).outputs.debug $c.njobs ($inv | where type == f) }
  relativize-sonames $c.out ($inv | where type == f and rel =~ '\.cmake$' | get path)
}

# no debug output yet, but CodeView LF_BUILDINFO in static libraries names the compiler's store path
def binaries-coff [c: record, inv: table]: nothing -> nothing {
  strip-archives $c.out ($inv | where type == f and rel =~ '\.(lib|obj|a)$')
  launchers $c
}

# --deny: a cross output must not mention build-machine packages
def relocate [c: record, inv: table]: nothing -> nothing {
  match $c.platform.binfmt {
    "elf" => { binaries-elf $c $inv }
    "macho" => { binaries-macho $c $inv }
    "coff" => { binaries-coff $c $inv }
  }
  let a = (attrs)
  let deny = (if $c.platform.cross { $a.buildDependencies | where { $in not-in $a.dependencies } | each { [--deny $in] } | flatten } else { [] })
  if $c.spec.prebuilt? != "ldso" { x reloc-fixup $c.out --dest $c.dest ...$deny }
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
    let r = (^env -i $"HOME=($env.NIX_BUILD_TOP)" ...($c.platform.emulator) ...$audit $"($root)/bin/($cmd.0)($c.platform.ext.exe)" ...($cmd | skip 1) | complete)
    if $r.exit_code != 0 or not ($"($r.stdout)($r.stderr)" | str contains $want) {
      error make {msg: $"version check: `($cmd | str join ' ')` did not print ($want) \(exit ($r.exit_code))\n($r.stdout)($r.stderr)"}
    }
    let missed = (if ($audit_out | path exists) { open --raw $audit_out | lines | uniq | where { $in not-in ($c.spec.tests?.dlopen? | default []) } } else { [] })
    if ($missed | is-not-empty) {
      error make {msg: $"version check: `($cmd | str join ' ')` dlopens ($missed | str join ', '), not in the closure \(a missing dependency, or tests.dlopen = [names] if optional)"}
    }
  }
  do $run $c.out
  # beside the copy: every store root the build saw, launch (bin/ launchers link to it), and the
  # transitive DLL dirs a PE launcher names (an ELF reaches those through the real store)
  let root = $"($env.NIX_BUILD_TOP)/relocated"
  mkdir $root
  let dlls = ((exports-of $c.out).dllDirs | each { path split | take 4 | path join })
  for d in ($c.roots ++ [($c.platform.launch | path dirname -n 2)] ++ $dlls | uniq) { ^ln -sf $d $root }
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
