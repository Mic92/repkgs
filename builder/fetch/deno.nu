#!/usr/bin/env nu
# Producer for fetch.denoDeps { source, root? }, first stage. deno.lock (version 4 or 5) pins
#   npm    "<name>@<version>[_peers]" -> sha512 SRI of the registry tarball
#   jsr    "@scope/name@<version>"    -> sha256 of jsr.io/@scope/name/<version>_meta.json, whose
#                                        `manifest` then pins every file of the package
#   remote "https://…"                 -> sha256 of that module
# This stage fetches tarballs, _meta.json files and https: modules; deno-files.nu runs once
# they exist, fetches the jsr modules the manifests list and lays out the DENO_DIR.
use dyn-drv.nu
use npm-registry.nu [split-id tarball-url flat-name]

const JSR = "https://jsr.io"

def main []: nothing -> nothing {
  let lock = (open --raw ([$env.source $env.root deno.lock] | path join) | from json)
  if ($lock.version? | default "3" | into int) < 4 {
    error make {msg: "denoDeps: deno.lock older than version 4, regenerate it with deno >= 2"}
  }

  # npm keys may carry a peer-dependency suffix: "vite@5.0.0_@types+node@20.0.0"
  let npm = ($lock.npm? | default {} | transpose key entry | each {|p|
    let id = (split-id ($p.key | str replace -r '_.*' ''))
    let url = (tarball-url $id.name $id.version)
    {name: $id.name, version: $id.version, url: $url, integrity: $p.entry.integrity, file: $"(flat-name $id.name)-($id.version).tgz"}
  } | uniq-by name version | dyn-drv fetchurls)

  let jsr = ($lock.jsr? | default {} | transpose key entry | each {|p|
    let id = (split-id $p.key)
    let url = $"($JSR)/($id.name)/($id.version)_meta.json"
    {name: $id.name, version: $id.version, url: $url, file: $"jsr-(flat-name $id.name)-($id.version)_meta.json", sha256: $p.entry.integrity}
  } | dyn-drv fetchurls)

  let https = ($lock.remote? | default {} | items {|url, sha256|
    {url: $url, file: ($url | url parse | $"($in.host)($in.path)"), sha256: $sha256}
  } | dyn-drv fetchurls)

  print -e $"denoDeps: ($npm | length) npm, ($jsr | length) jsr, ($https | length) https"
  dyn-drv stage deno-deps deno-files.nu {
    npm: ($npm | select name version url integrity out drv | rename -c {out: tarball})
    jsr: ($jsr | select name version url out drv | rename -c {out: meta})
    https: ($https | select url out drv | rename -c {out: src})
  } ([$npm $jsr $https] | flatten | get drv)
}
