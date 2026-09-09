# discover → resolve → decide → apply (docs/uptrack.md)

use purl.nu *
use version.nu *
use datasource.nu

const HOOKS = [resolve sources files verify]
const LIB = path self .
const UNPACK = path self unpack.nu
const KNOWN = {top: [upstream source pin watch locks], upstream: [purl allow prerelease every group cpe], watch: [url regex purl], source: [key url hash unpack name], locks: [go]}

def check-keys [file: path, what: string, r: record]: nothing -> nothing {
  let bad = $r | columns | where $it not-in ($KNOWN | get $what)
  if ($bad | is-not-empty) { error make {msg: $"($file): unknown ($what) keys ($bad | str join ', '). Known: ($KNOWN | get $what | str join ' ')"} }
}

# update.nu beside a sources.toml replaces pipeline stages by exporting any of $HOOKS. It runs in
# its own nu with this directory on the module path, gets records as nuon args, prints json.
def hook-exports [hook: path]: nothing -> list<string> {
  let names = ^$nu.current-exe --no-config-file -I $LIB -c $"use ($hook); scope modules | where name == 'update' | first | get commands.name | to json" | from json
  let bad = $names | where $it not-in $HOOKS
  if ($bad | is-not-empty) { error make {msg: $"($hook): unknown exports ($bad | str join ', '). Known: ($HOOKS | str join ' ')"} }
  $names
}

def hook [pkg: record, stage: string, ...args: record]: nothing -> oneof<table, record> {
  let call = $"use ($pkg.hook); update ($stage) ($args | each { to nuon --serialize } | str join ' ') | to json"
  let r = ^$nu.current-exe --no-config-file -I $LIB -c $call | complete
  if $r.exit_code != 0 { error make {msg: $"($pkg.hook) ($stage): ($r.stderr | str trim)"} }
  if ($r.stderr | is-not-empty) { print -e ($r.stderr | str trim) }
  $r.stdout | from json
}

def has-hook [pkg: record, stage: string]: nothing -> bool { $stage in $pkg.hooks }


# every sources.toml under root, validated
export def discover [root: path]: nothing -> table {
  glob $"($root)/**/sources.toml" | sort | each {|f|
    let t = open $f
    check-keys $f top $t
    check-keys $f upstream ($t.upstream? | default {})
    check-keys $f watch ($t.watch? | default {})
    check-keys $f locks ($t.locks? | default {})
    for s in ($t.source? | default []) { check-keys $f source $s }
    if $t.upstream?.purl? == null { error make {msg: $"($f): upstream.purl is required"} }
    let dir = $f | path dirname
    let hook = if ($dir | path join update.nu | path exists) { $dir | path join update.nu }
    {
      name: ($dir | path basename), dir: $dir, file: $f, hook: $hook
      hooks: (if $hook != null { hook-exports $hook } else { [] })
      upstream: $t.upstream, source: ($t.source? | default []), pin: ($t.pin? | default {})
      watch: ($t.watch? | default {}), locks: ($t.locks? | default {})
    }
  }
}

# what the skim asks for a package: its [watch] if set, else its purl
def watch-purl [pkg: record]: nothing -> record {
  if $pkg.watch.purl? != null { return (purl parse $pkg.watch.purl) }
  if $pkg.watch.url? != null { return {type: generic, namespace: '', name: $pkg.name, qualifiers: $pkg.watch} }
  purl parse $pkg.upstream.purl
}

# the only stage that talks to upstreams. Adds `candidates` (or `error`) per package
export def resolve [pkgs: table, --threads: int = 8]: nothing -> table {
  $pkgs | par-each --keep-order --threads $threads {|pkg|
    try {
      let c = if (has-hook $pkg resolve) { hook $pkg resolve $pkg } else { datasource versions (watch-purl $pkg) }
      $pkg | insert candidates $c | insert error null
    } catch {|e| $pkg | insert candidates [] | insert error $e.msg }
  }
}

# pure: pick a candidate per package and say why, or why not
export def decide [pkgs: table, --prerelease]: nothing -> table {
  $pkgs | each {|pkg|
    let u = $pkg.upstream
    let cur = $pkg.pin.version?
    let ok = $pkg.candidates
      | where {|c| $prerelease or ($u.prerelease? | default false) or not $c.prerelease }
      | where {|c| version satisfies $c.version $u.allow? }
    let young = if $u.every? == null { [] } else { $ok | where {|c| $c.date != null and ((date now) - ($c.date | into datetime)) < ($u.every | into duration) } }
    let ok = $ok | where {|c| $c not-in $young }
    let best = $ok | get version | version max
    let out = {name: $pkg.name, dir: $pkg.dir, file: $pkg.file, hook: $pkg.hook, hooks: $pkg.hooks, from: $cur, to: null, note: null}
    if $pkg.error != null {
      $out | update note $pkg.error
    } else if ($pkg.candidates | is-empty) {
      $out | update note "datasource returned no versions"
    } else if $best == null {
      $out | update note $"all ($pkg.candidates | length) candidates filtered by allow/prerelease/every"
    } else if $cur != null and (version cmp $best $cur) <= 0 {
      $out
    } else {
      let c = $ok | where version == $best | first
      let notes = [
        (if $c.date != null { $"released ($c.date | into datetime | format date '%F')" })
        (if ($young | is-not-empty) { $"($young | length) newer held by every=($u.every)" })
        (do { let p = $pkg.candidates | where prerelease | get version | where {|v| (version cmp $v $best) > 0 } | version max; if $p != null { $"pre-release ($p) ignored" } })
      ] | compact | str join ', '
      let sources = $pkg.source | each {|s| {key: $s.key, url: (expand $s.url $best ($c.tag? | default $best)), unpack: ($s.unpack? | default true)} }
      let entry = $out | merge {to: $best, note: $notes, candidate: $c, sources: $sources}
      if (has-hook $pkg sources) { $entry | merge (hook $pkg sources $pkg $entry) } else { $entry }
    }
  }
}

# {version} {version_} (dots as underscores) {major} {minor} {tag}
export def expand [tmpl: string, version: string, tag: string]: nothing -> string {
  let p = $version | split row '.'
  $tmpl | str replace -a '{version}' $version | str replace -a '{version_}' ($p | str join '_') | str replace -a '{major}' $p.0 | str replace -a '{minor}' ($p | get -o 1 | default '0') | str replace -a '{tag}' $tag
}

# the hash nix/sources.nix wants: for archives the NAR hash of the unpacked tree
# (bsdtar --strip-components 1, u+w: fetch and unpack are one fixed-output derivation), else the file's
export def prefetch [url: string, unpack: bool]: nothing -> string {
  let f = (^nix store prefetch-file --json $url | from json)
  if not $unpack { return $f.hash }
  let tmp = $"(mktemp -d -t uptrack-tree.XXXX)/src"
  ^nu --no-config-file $UNPACK $f.storePath $tmp
  let tree = (^nix hash path --sri --type sha256 $tmp | str trim)
  rm -rf ($tmp | path dirname)
  $tree
}

# re-prefetch every source at the current pin and rewrite its hash (no version change)
export def rehash [pkg: record]: nothing -> nothing {
  let t = open $pkg.file
  let pin = $t.pin? | default {}
  let version = $pin.version? | default ""
  let t = $t | upsert source ($t.source | each {|s|
    let url = expand $s.url $version ($pin.tag? | default $version)
    print -e $"  ($url)"
    $s | upsert hash (prefetch $url ($s.unpack? | default true))
  })
  $t | save -f $pkg.file
}

# prefetch the entry's sources and write hash + [pin] back to its sources.toml
export def apply [entry: record]: nothing -> record {
  let hashes = $entry.sources | each {|s|
    print -e $"  ($s.url)"
    # an upstream-published sha256 is the flat file hash, only usable for unpack = false
    let known = if (not $s.unpack) and $s.url == $entry.candidate.url? and $entry.candidate.sha256? != null { ^nix hash convert --hash-algo sha256 --to sri $entry.candidate.sha256 | str trim }
    {key: $s.key, hash: ($known | default { prefetch $s.url $s.unpack })}
  }
  let t = open $entry.file
  let t = $t | upsert source ($t.source | each {|s| $s | upsert hash ($hashes | where key == $s.key).0.hash })
  let c = $entry.candidate
  let pin = {
    version: $entry.to
    tag: $c.tag?
    date: (if $c.date != null { $c.date | into datetime | format date '%F' })
    checked: (date now | format date '%F')
    extra: $entry.extra?
  } | compact
  $t | upsert pin ($t.pin? | default {} | merge $pin) | save -f $entry.file
  # files hook: derived files beside the package ({relative path: content}), after the pin is written
  if (has-hook $entry files) {
    let files = hook $entry files $entry
    for f in ($files | transpose path content) {
      $f.content | save -f ($entry.dir | path join $f.path)
      print -e $"  wrote ($f.path)"
    }
  }
  $entry | insert applied true
}

# build the package through the tree adapter (or the verify hook) and record evidence
export def verify [entry: record, --attr: string]: nothing -> record {
  if (has-hook $entry verify) { return ($entry | merge (hook $entry verify $entry)) }
  let attr = $attr | default $entry.name
  let root = $env.UPTRACK_ROOT? | default $env.PWD
  let start = date now
  let r = ^nix-build $root -A $attr --no-out-link | complete
  let took = (date now) - $start
  if $r.exit_code != 0 {
    return ($entry | merge {verified: false, log: ($r.stderr | lines | last 40 | str join "\n"), took: $took})
  }
  let out = $r.stdout | str trim | lines | last
  let size = ^nix path-info -S --json $out | from json | values | first | get closureSize
  $entry | merge {verified: true, out: $out, closure: ($size | into filesize), took: $took}
}
