# locks/hackage.toml is the set's one Haskell version set (a rolling snapshot of our own):
#   <pkg> = { version, src, rev, cabal }
# `src` the sha256 of hackage's <pkg>-<version>.tar.gz (hackage publishes none, prefetched),
# `rev`/`cabal` the newest .cabal revision and its sha256 (hackage's JSON). fetch.hackageSet lays
# the whole table out as one file+noindex repository every cabal package solves against offline.
#
# Locking a package = `cabal freeze` of its source with the tree's ghc-bootstrap/cabal-bootstrap,
# the current set as solver preferences so packages agree on versions where they can. Entries that
# still come out different move (printed, verify the other Haskell packages then). GHC's boot
# packages appear in freeze output too and 404 on hackage: skipped.

use pipeline.nu

const HACKAGE = "https://hackage.haskell.org/package"

def prefetch [url: string]: nothing -> string {
  ^nix store prefetch-file --json --hash-type sha256 $url | from json | get hash
}

def tool [attr: string, bin: path]: nothing -> path {
  ^nix-build (pipeline root) -A $attr --no-out-link | str trim | path join bin $bin
}

# [{name version}] cabal's solver picks for the package unpacked at `src`, preferring `old`
def solve [src: path, old: record]: nothing -> table<name: string, version: string> {
  let ghc = (tool ghc-bootstrap ghc)
  let cabal = (tool cabal-bootstrap cabal)
  let home = ($env.XDG_CACHE_HOME? | default $"($env.HOME)/.cache" | path join uptrack cabal)
  let work = (mktemp -d)
  ^cp -r $"($src)/." $work
  let prefs = ($old | items {|n, e| $"any.($n) ==($e.version)" } | str join ", ")
  $"packages: .\npreferences: ($prefs)\n" | save -f $"($work)/cabal.project"
  let r = (with-env {CABAL_DIR: $home} {
    if not ($"($home)/packages" | path exists) { ^$cabal update o+e>| ignore }
    ^$cabal freeze $"--project-dir=($work)" -w $ghc --disable-tests --disable-benchmarks | complete
  })
  let freeze = (if $r.exit_code == 0 { open --raw $"($work)/cabal.project.freeze" } else { "" })
  rm -rf $work
  if $r.exit_code != 0 { error make {msg: $"cabal freeze: ($r.stderr | lines | last 8 | str join "\n")"} }
  $freeze | parse -r 'any\.([A-Za-z0-9-]+) ==([0-9.]+)' | rename name version | uniq-by name
}

# the entries of the set the package at `src` needs: {<pkg>: {version src rev cabal}}
export def lock [src: path, old: record = {}]: nothing -> record {
  solve $src $old | par-each --threads 8 {|p|
    let prev = ($old | get -o $p.name)
    if $prev != null and $prev.version == $p.version { return {key: $p.name, val: $prev} }
    let id = $"($p.name)-($p.version)"
    let r = (http get --full --allow-errors --headers {Accept: application/json} $"($HACKAGE)/($id)/revisions/")
    if $r.status != 200 { return null }
    let last = ($r.body | last)
    print -e $"  ($id) r($last.number)(if $prev != null { $' \(was ($prev.version)\)' })"
    {key: $p.name, val: {
      version: $p.version
      src: (prefetch $"($HACKAGE)/($id)/($id).tar.gz")
      rev: ($last.number | into string)
      cabal: $"sha256-($last.sha256 | decode hex | encode base64)"
    }}
  } | compact | sort-by key | each {|r| [$r.key $r.val] } | into record
}
