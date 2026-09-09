#!/usr/bin/env nu
# Producer for fetch.bunDeps { source, root? }.
#
# bun.lock (text JSONC, lockfileVersion >= 1) maps each resolved package to
#   ["name@version", "<registry url or empty>", {metadata}, "sha512-…"]
# Registry packages become builtin:fetchurl derivations fixed by that integrity and are unpacked
# into the output: { p/<name>@<version>/…, index.json [{id, dir}] }. builder/bun.nu links those
# directories into $BUN_INSTALL_CACHE_DIR under the names bun expects (builder/bun-cache.ts).
# workspace: entries are the project itself; github:/git:/file: ones carry no hash and are rejected.
use dynamic.nu
use npm-registry.nu [split-id tarball-url flat-name]

def main []: nothing -> nothing {
  let lock = (read-jsonc ([$env.source $env.root bun.lock] | path join))
  let entries = ($lock.packages | transpose key value | each {|e|
    {key: $e.key, id: $e.value.0, registry: ($e.value | get 1), integrity: ($e.value | last)}
  })
  let from_registry = ($entries | where { ($in.integrity | describe) == string and ($in.integrity | str starts-with "sha512-") })
  let unhashed = ($entries | where key not-in ($from_registry | get key) | where id !~ "@workspace:")
  if ($unhashed | is-not-empty) {
    error make {msg: $"bunDeps: bun.lock has no integrity for ($unhashed | get id | str join ', ') \(git/github/file dependencies)"}
  }

  let fetched = ($from_registry | uniq-by id | each {|entry|
    let p = (split-id $entry.id)
    {id: $entry.id, dir: $"p/(flat-name $p.name)@($p.version)"}
      | merge (dynamic fetchurl-sri $"(flat-name $p.name)-($p.version).tgz" (tarball-url $p.name $p.version $entry.registry) $entry.integrity)
  })
  let unpack = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    let out = $attrs.outputs.out
    for p in $attrs.packages {
      mkdir $"($out)/($p.dir)"
      ^$"($attrs.seed)/bin/bsdtar" -xf $p.src -C $"($out)/($p.dir)" --strip-components 1 --no-same-owner --no-same-permissions
    }
    ^$"($attrs.seed)/bin/chmod" -R u+w,a-st $out
    $attrs.packages | select id dir | to json | save $"($out)/index.json"'
  dynamic submit bun-deps $unpack {packages: ($fetched | select id dir out | rename -c {out: src})} ($fetched | get drv)
}

# bun writes trailing commas but no comments
def read-jsonc [file: path]: nothing -> record { open --raw $file | str replace -ar ',(\s*[}\]])' '$1' | from json }

