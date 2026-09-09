# discover → resolve → decide → apply → verify (docs/uptrack.md). Each stage takes and returns
# package records; only `resolve` talks to upstreams, only `apply` writes files.

use purl.nu *
use version.nu *
use datasource.nu

const LIB = path self .
const UNPACK = path self unpack.nu

# the keys a sources.toml may carry, per table
const KNOWN = {
  top: [upstream source pin watch locks]
  upstream: [purl allow prerelease every group cpe frozen relocks]
  watch: [url regex purl]
  source: [key url hash unpack name]
  locks: [go hackage]
}
# stages an update.nu beside sources.toml may replace
const HOOKS = [resolve files verify]

# the package tree: $UPTRACK_ROOT, default the working directory
export def root []: nothing -> path { $env.UPTRACK_ROOT? | default $env.PWD }

def check-keys [file: path, table: string, r: record]: nothing -> nothing {
  let bad = ($r | columns | where $it not-in ($KNOWN | get $table))
  if ($bad | is-not-empty) {
    error make {msg: $"($file): unknown ($table) keys ($bad | str join ', '). Known: ($KNOWN | get $table | str join ' ')"}
  }
}

# every sources.toml under `dir`, validated, as package records
export def discover [dir: path]: nothing -> table {
  glob $"($dir)/**/sources.toml" | sort | each {|f|
    let t = ({upstream: {}, source: [], pin: {}, watch: {}, locks: {}} | merge (open $f))
    check-keys $f top $t
    for table in [upstream watch locks] { check-keys $f $table ($t | get $table) }
    # in-tree sources (source = ./src) have nothing to track but may still lock dependencies.
    # `frozen = "<reason>"` pins a dead upstream: nothing to poll, hash stays as written
    let tracked = ($t.upstream.purl? != null)
    let frozen = ($t.upstream.frozen? != null)
    if not $tracked and not $frozen and (($t.source | is-not-empty) or ($t.locks | is-empty)) { error make {msg: $"($f): upstream.purl \(or frozen\) is required"} }
    for s in $t.source {
      check-keys $f source $s
      # a bump would keep fetching the old file under the new version
      if $tracked and $s.url !~ '\{' { error make {msg: $"($f): source ($s.key) url has no {placeholder}"} }
    }
    let dir = ($f | path dirname)
    let hook = ($dir | path join update.nu)
    let hook = (if ($hook | path exists) { $hook })
    $t | merge {name: ($dir | path basename), dir: $dir, file: $f, tracked: $tracked, hook: $hook, hooks: (if $hook != null { hook-exports $hook } else { [] })}
  }
}

# Adds `candidates` [{version date prerelease tag? url? sha256?}] and `error` per package
export def resolve [pkgs: table, --threads: int = 8]: nothing -> table {
  $pkgs | par-each --keep-order --threads $threads {|pkg|
    try {
      let c = (if (has-hook $pkg resolve) { hook $pkg resolve $pkg } else { datasource versions (watch-purl $pkg) })
      $pkg | merge {candidates: $c, error: null}
    } catch {|e| $pkg | merge {candidates: [], error: $e.msg} }
  }
}

# what to ask upstream for: [watch] if set, else the purl
def watch-purl [pkg: record<name: string, upstream: record, watch: record>]: nothing -> record<type: string, namespace: string, name: string, qualifiers: record> {
  if $pkg.watch.purl? != null {
    purl parse $pkg.watch.purl
  } else if $pkg.watch.url? != null {
    {type: generic, namespace: "", name: $pkg.name, qualifiers: $pkg.watch}
  } else {
    purl parse $pkg.upstream.purl
  }
}

# Adds `from`, `to` (null: nothing to do), `note` (why, or why not) and, when there is an update,
# `pin` (the [pin] table to write) and the expanded `sources` [{key url unpack}]. Pure.
export def decide [pkgs: table, --prerelease]: nothing -> table {
  $pkgs | each {|pkg|
    let u = $pkg.upstream
    let current = $pkg.pin.version?
    let allowed = ($pkg.candidates
      | where {|c| $prerelease or ($u.prerelease? | default false) or not $c.prerelease }
      | where {|c| version satisfies $c.version $u.allow? })
    # `every`: ignore releases younger than the interval
    let too_young = (if $u.every? == null { [] } else {
      $allowed | where {|c| $c.date != null and ((date now) - ($c.date | into datetime)) < ($u.every | into duration) }
    })
    let eligible = ($allowed | where {|c| $c not-in $too_young })
    let best = ($eligible | get version | version max)
    let entry = ($pkg | merge {from: $current, to: null, note: null})
    let problem = ([
      $pkg.error
      (if ($pkg.candidates | is-empty) { "datasource returned no versions" })
      (if $best == null { $"all ($pkg.candidates | length) candidates filtered by allow/prerelease/every" })
    ] | compact | get -o 0)
    if $problem != null { return ($entry | update note $problem) }
    if $current != null and (version cmp $best $current) <= 0 { return $entry }
    let c = ($eligible | where version == $best | first)
    let newer_pre = ($pkg.candidates | where prerelease | get version | where {|v| (version cmp $v $best) > 0 } | version max)
    let note = ([
      (if $c.date != null { $"released ($c.date | into datetime | format date '%F')" })
      (if ($too_young | is-not-empty) { $"($too_young | length) newer held by every=($u.every)" })
      (if $newer_pre != null { $"pre-release ($newer_pre) ignored" })
    ] | compact | str join ", ")
    # [pin] = the candidate minus datasource bookkeeping. Whatever else a resolve hook put there
    # (jdk-bootstrap's file name spelling) is kept and usable as {key} in urls
    let pin = ($c | reject -o prerelease url sha256 | upsert date {|c| if $c.date? != null { $c.date | into datetime | format date '%F' } } | compact)
    let sources = ($pkg.source | each {|s| {key: $s.key, url: (expand $s.url $pin), unpack: ($s.unpack? | default true)} })
    $entry | merge {to: $best, note: $note, candidate: $c, pin: $pin, sources: $sources}
  }
}

# url templates: every [pin] key as {key}, plus {version_} (dots as underscores) {major} {minor},
# and {tag} falling back to the version
export def expand [template: string, pin: record]: nothing -> string {
  let parts = ($pin.version | split row ".")
  {tag: $pin.version, version_: ($parts | str join "_"), major: $parts.0, minor: ($parts | get -o 1 | default "0")}
    | merge $pin
    | items {|k, v| [$"{($k)}" ($v | into string)] }
    | reduce --fold $template {|kv, acc| $acc | str replace -a $kv.0 $kv.1 }
}

# the hash nix/sources.nix expects: the NAR hash of the unpacked tree (unpack.nu, shared with the
# fetcher), or the file's own for `unpack = false`
export def prefetch [url: string, unpack: bool]: nothing -> string {
  let f = (^nix store prefetch-file --json $url | from json)
  if not $unpack { return $f.hash }
  let tmp = $"(mktemp -d -t uptrack-tree.XXXX)/src"
  ^$nu.current-exe --no-config-file $UNPACK $f.storePath $tmp
  let tree = (^nix hash path --sri --type sha256 $tmp | str trim)
  rm -rf ($tmp | path dirname)
  $tree
}

# sources.toml with `hash` filled in for every [[source]], urls expanded for `pin`.
# `known`: key -> hash already at hand (an upstream-published sha256), not prefetched again
def with-hashes [t: record<source: list<any>>, pin: record, known: record = {}]: nothing -> record {
  $t | update source ($t.source | each {|s|
    let url = (expand $s.url $pin)
    print -e $"  ($url)"
    $s | upsert hash ($known | get -o $s.key | default { prefetch $url ($s.unpack? | default true) })
  })
}

# re-prefetch every source at the current pin (after editing a url), no version change
export def rehash [pkg: record<file: string>]: nothing -> nothing {
  let t = (open $pkg.file)
  if $t.pin?.version? == null { error make {msg: $"($pkg.file): no [pin] version to rehash at"} }
  with-hashes $t $t.pin | save -f $pkg.file
}

# write hashes + [pin] for the decided update into sources.toml, then the `files` hook's outputs
export def apply [entry: record]: nothing -> nothing {
  let c = $entry.candidate
  # a registry-published sha256 is the flat file's: usable only where we keep the file as is
  let known = ($entry.sources | where { not $in.unpack and $in.url == $c.url? and $c.sha256? != null }
    | each {|s| {$s.key: (^nix hash convert --hash-algo sha256 --to sri $c.sha256 | str trim)} } | into record)
  with-hashes (open $entry.file) $entry.pin $known | upsert pin $entry.pin | save -f $entry.file
  if (has-hook $entry files) {
    for f in (hook $entry files $entry | transpose path content) {
      $f.content | save -f ($entry.dir | path join $f.path)
      print -e $"  wrote ($f.path)"
    }
  }
}

# nix-build the package (or run its verify hook): adds verified, took, and out/closure or log
export def verify [pkg: record]: nothing -> record {
  if (has-hook $pkg verify) { return ($pkg | merge (hook $pkg verify $pkg)) }
  let start = (date now)
  let r = (^nix-build (root) -A $pkg.name --no-out-link | complete)
  let took = ((date now) - $start)
  if $r.exit_code != 0 {
    return ($pkg | merge {verified: false, took: $took, log: ($r.stderr | lines | last 40 | str join "\n")})
  }
  let out = ($r.stdout | lines | last)
  let closure = (^nix path-info -S --json $out | from json | values | first | get closureSize | into filesize)
  $pkg | merge {verified: true, took: $took, out: $out, closure: $closure}
}

# --- update.nu hooks ------------------------------------------------------------------------------
# An update.nu beside sources.toml may export any of $HOOKS to replace that stage for its package.
# It runs in its own nu with this directory on the module path, gets records as nuon arguments
# and answers in json.

def has-hook [pkg: record, stage: string]: nothing -> bool { $stage in $pkg.hooks }

def hook-exports [file: path]: nothing -> list<string> {
  let names = (run-nu $"use ($file); scope modules | where name == 'update' | first | get commands.name | to json" $file)
  let bad = ($names | where $it not-in $HOOKS)
  if ($bad | is-not-empty) { error make {msg: $"($file): unknown exports ($bad | str join ', '). Known: ($HOOKS | str join ' ')"} }
  $names
}

def hook [pkg: record, stage: string, ...args: record]: nothing -> oneof<table, record> {
  run-nu $"use ($pkg.hook); update ($stage) ($args | each { to nuon --serialize } | str join ' ') | to json" $"($pkg.hook) ($stage)"
}

def run-nu [code: string, what: string]: nothing -> oneof<table, record, list<string>> {
  let r = (^$nu.current-exe --no-config-file -I $LIB -c $code | complete)
  if $r.exit_code != 0 { error make {msg: $"($what): ($r.stderr | str trim)"} }
  if ($r.stderr | is-not-empty) { print -e ($r.stderr | str trim) }
  $r.stdout | from json
}
