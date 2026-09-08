# locks.toml [go] from a source tree's go.sum: every module version go.sum names, with the sha256
# of its proxy.golang.org .zip and .mod (go.sum's h1: is a hash over the zip's file list, not of
# the zip, so Nix cannot fix a download by it). fetch.goModules turns the lock into one
# builtin:fetchurl per file; `go` re-verifies h1: against go.sum when it reads them.

# module path as the proxy spells it: upper case -> !lower
export def escape [m: string]: nothing -> string { $m | str replace -ar "([A-Z])" "!$1" | str downcase }

def prefetch [url: string]: nothing -> string {
  ^nix store prefetch-file --json --hash-type sha256 $url | from json | get hash
}

# go.sum rows with their table key
export def sums [dir: path]: nothing -> table {
  open --raw ($dir | path join go.sum) | lines | where $it != "" | split column " " mod ver h1
    | insert key { $"($in.mod)@($in.ver | str replace '/go.mod' '')" }
}

# {"<module>@<version>": {mod: sri, zip?: sri}} for the go.sum under `dir`. `old` is the previous
# lock: unchanged entries are not fetched again
export def lock [dir: path, old: record = {}]: nothing -> record {
  sums $dir | group-by key --to-table | par-each --threads 8 {|g|
    let prev = $old | get -o $g.key
    if $prev != null { return {key: $g.key, val: $prev} }
    let i = $g.items.0
    let base = $"https://proxy.golang.org/(escape $i.mod)/@v/($i.ver | str replace '/go.mod' '')"
    # go.sum lists h1 for go.mod alone when only the module graph needed it: no zip then
    let want_zip = $g.items | any {|r| $r.ver !~ '/go.mod$' }
    print -e $"  ($g.key)"
    {key: $g.key, val: ({mod: (prefetch $"($base).mod"), zip: (if $want_zip { prefetch $"($base).zip" })} | compact)}
  } | sort-by key | transpose -rd | default {}
}
