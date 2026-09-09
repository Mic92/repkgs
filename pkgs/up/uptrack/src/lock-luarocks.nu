# locks/luarocks.toml: the set's rock versions, <rock> = { version, sha256 }, `sha256` of
# luarocks.org's <rock>-<version>.src.rock (the manifest publishes none). Locking a package lets
# the tree's luarocks build its rockspec's dependencies from luarocks.org into a scratch tree and
# records what it installed. A rock another package locked at a different version moves (printed).

use pipeline.nu

const LUAROCKS = "https://luarocks.org"

# [{name version}] luarocks installs for the rockspec under `src`
def solve [src: path]: nothing -> table<name: string, version: string> {
  # luarocks, and the tree's cc for C modules
  let bins = (^nix-build (pipeline root) -A luarocks -A toolchain --no-out-link | lines | each { path join bin })
  let luarocks = ($bins.0 | path join luarocks)
  let work = (mktemp -d)
  ^cp -r $"($src)/." $work
  chmod -R u+w $work
  let r = (with-env {PATH: ($env.PATH | prepend $bins), PWD: $work} {
    ^$luarocks make --tree $"($work)/.tree" --only-deps --deps-mode one $"--only-server=($LUAROCKS)" | complete
  })
  let rows = (^$luarocks list --tree $"($work)/.tree" --porcelain | lines | split column "\t" name version | select name version)
  rm -rf $work
  if $r.exit_code != 0 { error make {msg: $"luarocks make: ($r.stdout + $r.stderr | lines | last 10 | str join "\n")"} }
  $rows
}

# the entries of the set the package at `src` needs: {<rock>: {version sha256}}
export def lock [src: path, old: record = {}]: nothing -> record {
  solve $src | each {|p|
    let prev = ($old | get -o $p.name)
    if $prev != null and $prev.version == $p.version { return [$p.name $prev] }
    print -e $"  ($p.name) ($p.version)(if $prev != null { $' \(was ($prev.version)\)' })"
    let hash = (^nix store prefetch-file --json --hash-type sha256 $"($LUAROCKS)/($p.name)-($p.version).src.rock" | from json | get hash)
    [$p.name {version: $p.version, sha256: $hash}]
  } | into record
}
