#!/usr/bin/env nu
# Producer for fetch.pnpmDeps { source, root? }: pnpm-lock.yaml v9 lists every registry package
# under `packages:` as `name@version` with `resolution.integrity` (SRI); the tarball URL is the
# registry's canonical one unless `resolution.tarball` says otherwise. Each becomes a
# builtin:fetchurl fixed by that hash, laid out as a registry mirror (registry/<url path>) that
# pnpm.nu installs from with registry=file:/… --offline: pnpm derives the same paths from the lock.
use dyn-drv.nu
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
    {id: $p.id, file: ($url | url parse | get path | str trim --left --char "/"), url: $url, integrity: $p.val.resolution.integrity}
  } | uniq-by file | dyn-drv fetchurls)
  dyn-drv collect pnpm-deps ($fetched | each {|f| {link: $f.out, to: $"registry/($f.file)"} }) ($fetched | get drv)
}
