#!/usr/bin/env nu
# Producer for fetch.npmDeps { source, root?, lockFile? }: every registry package in a
# package-lock.json (v2/v3) has `resolved` (tarball URL) and `integrity` (SRI), so each becomes a
# builtin:fetchurl fixed by that very hash. The collector writes a package-lock.json whose
# `resolved` point at the store tarballs; npm.nu drops it in and `npm ci --offline` verifies
# integrity itself.
use dynamic.nu

def main []: nothing -> nothing {
  let lock_file = (if $env.lockFile != "" { $env.lockFile } else { [$env.source $env.root package-lock.json] | path join })
  let lock = (open --raw $lock_file | from json)
  if ($lock.lockfileVersion? | default 1) < 2 {
    error make {msg: "npmDeps: package-lock.json v1 is not supported (run `npm i --lockfile-version 3`)"}
  }
  # workspace links and bundled deps have no `resolved`; everything fetched needs `integrity`
  let remote = ($lock.packages | transpose key val | where { $in.val.resolved? != null })
  let foreign = ($remote | where { $in.val.resolved !~ '^https?://' })
  if ($foreign | is-not-empty) { error make {msg: $"npmDeps: unsupported `resolved` (git/file) for: ($foreign | get key | str join ', ')"} }
  let unhashed = ($remote | where { $in.val.integrity? == null })
  if ($unhashed | is-not-empty) { error make {msg: $"npmDeps: no `integrity` for: ($unhashed | get key | str join ', ')"} }
  # the same tarball can appear under several node_modules paths: fetch once per URL
  let fetched = ($remote | each {|e| {url: $e.val.resolved, integrity: $e.val.integrity} } | uniq-by url | each {|e|
    {url: $e.url} | merge (dynamic fetchurl-sri ($e.url | url parse | get path | path basename) $e.url $e.integrity)
  })
  let by_url = ($fetched | reduce --fold {} {|f, acc| $acc | insert $f.url $f.out })
  let new_lock = ($lock | reject -o dependencies | update packages {|l|
    $l.packages | items {|key, val|
      {$key: (if $val.resolved? == null { $val } else { $val | update resolved $"file:($by_url | get $val.resolved)" })}
    } | reduce {|it| merge $it }
  })
  # structured attrs: the lock is far beyond execve's env limit
  let collect = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    mkdir $attrs.outputs.out
    $attrs.lock | to json | save $"($attrs.outputs.out)/package-lock.json"'
  dynamic submit npm-deps $collect {lock: $new_lock} ($fetched | get drv)
}
