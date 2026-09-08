#!/usr/bin/env nu
# Producer for fetch.pnpmDeps { source, root? }: pnpm-lock.yaml v9 lists every registry package
# under `packages:` as `name@version` with `resolution.integrity` (SRI); the tarball URL is the
# registry's canonical one unless `resolution.tarball` says otherwise. Each becomes a
# builtin:fetchurl fixed by that hash. Output: { tarballs/*.tgz, index.json [{id, file}] }, which
# pnpm.nu seeds an offline pnpm store from (`pnpm store add`), then installs --offline.
use dynamic.nu

const REGISTRY = "https://registry.npmjs.org"

# '@scope/name@1.2.3' | 'name@1.2.3' -> {name, version}; the version starts at the last '@' past position 0
def split-id [id: string]: nothing -> record<name: string, version: string> {
  let at = ($id | str substring 1.. | str index-of -e "@") + 1
  {name: ($id | str substring ..<$at), version: ($id | str substring ($at + 1)..)}
}

def tarball-url [name: string, version: string]: nothing -> string {
  $"($REGISTRY)/($name)/-/($name | split row "/" | last)-($version).tgz"
}

def main []: nothing -> nothing {
  let lock_file = ([$env.source $env.root pnpm-lock.yaml] | path join)
  let lock = (open --raw $lock_file | from yaml)
  let v = ($lock.lockfileVersion? | default "0" | into string)
  if not ($v | str starts-with "9.") { error make {msg: $"pnpmDeps: pnpm-lock.yaml version ($v), only 9.x is supported \(pnpm >= 9)"} }
  let pkgs = ($lock.packages? | default {} | transpose id val)
  let foreign = ($pkgs | where { $in.val.resolution?.integrity? == null })
  if ($foreign | is-not-empty) { error make {msg: $"pnpmDeps: no integrity \(git/file/directory resolution) for: ($foreign | get id | str join ', ')"} }
  let fetched = ($pkgs | each {|p|
    let nv = (split-id $p.id)
    let url = ($p.val.resolution.tarball? | default (tarball-url $nv.name $nv.version))
    let file = $"($nv.name | str replace "/" "+")-($nv.version).tgz"
    {id: $p.id, file: $file} | merge (dynamic fetchurl-sri $file $url $p.val.resolution.integrity)
  })
  let collect = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    let out = $attrs.outputs.out
    mkdir $"($out)/tarballs"
    for t in $attrs.tarballs { ^$"($attrs.seed)/bin/ln" -s $t.src $"($out)/tarballs/($t.file)" }
    $attrs.tarballs | select id file | to json | save $"($out)/index.json"'
  dynamic submit pnpm-deps $collect {tarballs: ($fetched | each {|f| {id: $f.id, file: $f.file, src: $f.out} })} ($fetched | get drv)
}
