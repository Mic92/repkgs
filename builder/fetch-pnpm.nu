#!/usr/bin/env nu
# Producer for fetch.pnpmDeps { source, root? }: pnpm-lock.yaml v9 lists every registry package
# under `packages:` as `name@version` with `resolution.integrity` (SRI); the tarball URL is the
# registry's canonical one unless `resolution.tarball` says otherwise. Each becomes a
# builtin:fetchurl fixed by that hash. Output: { tarballs/*.tgz, index.json [{id, file}] }, which
# pnpm.nu seeds an offline pnpm store from (`pnpm store add`), then installs --offline.
use dynamic.nu
use npm-registry.nu [split-id tarball-url]

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
  let layout = [
    ...($fetched | each {|f| {link: $f.out, to: $"tarballs/($f.file)"} })
    (dynamic json-file index.json ($fetched | select id file))
  ]
  dynamic collect pnpm-deps $layout ($fetched | get drv)
}
