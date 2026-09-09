# The repo-wide locks/<eco>.toml (file format, and filling it from packages' [locks]): `[<eco>]` then one `"<key>" = { ... }` line per entry, sorted.
# Line-oriented so concurrent additions merge textually (.gitattributes: merge=union); `write`
# is the normal form, `normalize` repairs what a union merge leaves (order, duplicate lines).

use lock-go.nu

# entries of <dir>/<eco>.toml, {} when absent
export def read [dir: path, eco: string]: nothing -> record {
  let f = $dir | path join $"($eco).toml"
  if ($f | path exists) { open $f | get $eco } else { {} }
}

def render [eco: string, entries: record]: nothing -> string {
  let lines = $entries | transpose k v | sort-by k | each {|e|
    let fields = $e.v | transpose f h | sort-by f | each {|x| $"($x.f) = \"($x.h)\"" } | str join ", "
    $"\"($e.k)\" = { ($fields) }"
  }
  ([$"[($eco)]"] ++ $lines | str join "\n") + "\n"
}

# replace <dir>/<eco>.toml with `entries` in normal form
export def write [dir: path, eco: string, entries: record]: nothing -> nothing {
  mkdir $dir
  render $eco $entries | save -f ($dir | path join $"($eco).toml")
}

# rewrite a locks file in normal form. Duplicate lines from a union merge are dropped before
# parsing (TOML rejects duplicate keys); differing values for one key stay an error
export def normalize [file: path]: nothing -> nothing {
  let eco = $file | path parse | get stem
  let raw = open --raw $file
  let entries = try { $raw | from toml | get $eco } catch { $raw | lines | uniq | str join "\n" | from toml | get $eco }
  let norm = render $eco $entries
  if $norm != (open --raw $file) { $norm | save -f $file }
}

# treefmt entry point
# add this package's dependencies ([locks] go = "<dir in source>") to the tree's
# locks/<eco>.toml ($UPTRACK_LOCKS, default <root>/locks), from the source at the current pin
# (fetched through `<name>.src`). Entries already in the table are not fetched again
export def add [pkg: record, --attr: string]: nothing -> record {
  if ($pkg.locks | is-empty) { return {} }
  let root = $env.UPTRACK_ROOT? | default $env.PWD
  let d = (dir)
  let src = ^nix-build $root -A $"($attr | default $pkg.name).src" --no-out-link | str trim
  $pkg.locks | items {|eco, sub|
    let old = read $d $eco
    let mine = match $eco { "go" => (lock-go lock ($src | path join $sub) $old) }
    let new = $old | merge $mine
    print -e $"  ($eco): ($mine | columns | length) entries, (($new | columns | length) - ($old | columns | length)) new"
    write $d $eco $new
    {$eco: ($mine | columns)}
  } | reduce -f {} {|it, acc| $acc | merge $it }
}

# $UPTRACK_LOCKS, default <root>/locks
export def dir []: nothing -> path { $env.UPTRACK_LOCKS? | default ($env.UPTRACK_ROOT? | default $env.PWD | path join locks) }

# rewrite each table to exactly the keys `used` names (eco -> list of keys), dropping the rest
export def prune [used: record]: nothing -> nothing {
  let d = (dir)
  for u in ($used | transpose eco keys) {
    let old = read $d $u.eco
    let kept = $old | select ...($u.keys | uniq)
    print -e $"($u.eco): kept ($kept | columns | length), dropped (($old | columns | length) - ($kept | columns | length))"
    write $d $u.eco $kept
  }
}


def main [...files: path]: nothing -> nothing { for f in $files { normalize $f } }
