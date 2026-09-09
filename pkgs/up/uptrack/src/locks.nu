# The repo-wide locks/<eco>.toml (file format, and filling it from packages' [locks]): `[<eco>]` then one `"<key>" = { ... }` line per entry, sorted.
# Line-oriented so concurrent additions merge textually (.gitattributes: merge=union); `write`
# is the normal form, `normalize` repairs what a union merge leaves (order, duplicate lines).

use lock-go.nu
use lock-hackage.nu
use pipeline.nu

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

# add this package's dependencies ([locks] go = "<dir in source>") to <dir>/<eco>.toml from the
# source at the current pin (built as `<name>.src`); entries already present are not fetched
# again. Returns [{eco, keys}]: what this package uses, for prune
export def add [pkg: record]: nothing -> table<eco: string, keys: list<string>> {
  if ($pkg.locks | is-empty) { return [] }
  # fetched sources are derivations (nix-build), in-tree ones (source = ./src) plain paths
  let src = (^nix-build (pipeline root) -A $"($pkg.name).src" --no-out-link | complete)
  let src = (if $src.exit_code == 0 { $src.stdout } else { ^nix eval --raw -f (pipeline root) $"($pkg.name).src" } | str trim)
  $pkg.locks | items {|eco, sub|
    let old = (read (dir) $eco)
    let mine = (match $eco {
      "go" => (lock-go lock ($src | path join $sub) $old)
      "hackage" => (lock-hackage lock ($src | path join $sub) $old)
    })
    let new = ($old | merge $mine)
    print -e $"  ($eco): ($mine | columns | length) entries, (($new | columns | length) - ($old | columns | length)) new"
    write (dir) $eco $new
    {eco: $eco, keys: ($mine | columns)}
  }
}

# $UPTRACK_LOCKS, default <root>/locks
export def dir []: nothing -> path { $env.UPTRACK_LOCKS? | default (pipeline root | path join locks) }

# rewrite each table to exactly the keys in `used` ([{eco, keys}]), dropping the rest
export def prune [used: table<eco: string, keys: list<string>>]: nothing -> nothing {
  for u in $used {
    let old = (read (dir) $u.eco)
    let kept = ($old | select ...$u.keys)
    print -e $"($u.eco): kept ($kept | columns | length), dropped (($old | columns | length) - ($kept | columns | length))"
    write (dir) $u.eco $kept
  }
}

# treefmt entry point
def main [
  ...files: path # locks/<eco>.toml to normalize in place
]: nothing -> nothing { for f in $files { normalize $f } }
