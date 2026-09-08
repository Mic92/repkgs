# The repo-wide locks/<eco>.toml: `[<eco>]` then one `"<key>" = { ... }` line per entry, sorted.
# Line-oriented so concurrent additions merge textually (.gitattributes: merge=union); `write`
# is the normal form, `normalize` repairs what a union merge leaves (order, duplicate lines).

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
def main [...files: path]: nothing -> nothing { for f in $files { normalize $f } }
