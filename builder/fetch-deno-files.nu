#!/usr/bin/env nu
# Second stage of fetch.denoDeps (after fetch-deno.nu; `stage_attrs` names its {npm, jsr, https}).
# Reads the fetched jsr _meta.json files: each module they list becomes a builtin:fetchurl fixed
# by the manifest's sha256, and the collecting derivation lays out what deno reads under $DENO_DIR.
use dynamic.nu

const JSR = "https://jsr.io"

def main []: nothing -> nothing {
  let fetched = (open $env.stage_attrs)
  let modules = ($fetched.jsr | each {|p| jsr-modules $p } | flatten | dynamic fetchurls)
  print -e $"denoDeps: ($modules | length) jsr modules"

  # remote/<scheme>/<host>[_PORT<n>]/<sha256 of path?query>, each with deno's metadata trailer
  let remote = [
    ...($modules | select url content_type out)
    ...($fetched.https | insert content_type {|m| content-type $m.url } | rename -c {src: out})
    ...($fetched.jsr | each {|p| {url: $p.url, content_type: "application/json", out: $p.meta} })
  ] | each {|f| {copy: $f.out, append: (trailer $f), to: (cache-path $f.url)} }
  let version_lists = ($fetched.jsr | group-by name | items {|name, versions|
    let f = {url: $"($JSR)/($name)/meta.json", content_type: "application/json"}
    {write: $"({versions: ($versions | each {|v| {$v.version: {}} } | into record)} | to json -r)(trailer $f)", to: (cache-path $f.url)}
  })
  # npm/registry.npmjs.org/<name>/<version>/ + a registry.json cut to the locked versions ("full" and
  # dist.tarball present: deno asks the registry nothing more)
  let npm = [
    ...($fetched.npm | each {|v| {unpack: $v.tarball, to: $"npm/registry.npmjs.org/($v.name)/($v.version)"} })
    ...($fetched.npm | group-by name | items {|name, versions|
      let listed = ($versions | each {|v| {$v.version: {version: $v.version, dependencies: {}, dist: {tarball: $v.url, integrity: $v.integrity}}} } | into record)
      dynamic json-file $"npm/registry.npmjs.org/($name)/registry.json" {name: $name, dist-tags: {}, "_deno.packumentFormat": full, versions: $listed}
    })
  ]
  dynamic collect deno-deps [...$remote ...$version_lists ...$npm] ($modules | get drv)
}

# where deno's global cache keeps a URL
def cache-path [url: string]: nothing -> string {
  let u = ($url | url parse)
  let key = ($"($u.path)(if $u.query != "" { $"?($u.query)" })" | hash sha256)
  $"remote/($u.scheme)/($u.host)(if $u.port != "" { $"_PORT($u.port)" })/($key)"
}

# what deno appends to a cached body: the response headers it cares about and the URL
def trailer [f: record<url: string, content_type: string>]: nothing -> string {
  $"\n// denoCacheMetadata=({headers: {content-type: $f.content_type}, url: $f.url} | to json -r)"
}

# the loadable modules of one jsr package version as `fetchurls` rows. jsr's publish-time module
# graph names them; test data, docs and CI files in the manifest are not fetched
def jsr-modules [p: record<name: string, version: string, meta: string>]: nothing -> table<url: string, content_type: string, file: string, sha256: string> {
  let meta = (open --raw $p.meta | from json)
  let graph = ($meta.moduleGraph2? | default $meta.moduleGraph1? | default {})
  $meta.manifest | transpose path file | where {|m| $graph has $m.path } | each {|m|
    let url = $"($JSR)/($p.name)/($p.version)($m.path)"
    {url: $url, content_type: (content-type $url), file: $"jsr-($p.name)-($p.version)($m.path)", sha256: ($m.file.checksum | str replace "sha256-" "")}
  }
}

# the lock records no content-type; deno picks the loader by it, so derive it from the extension
def content-type [url: string]: nothing -> string {
  match ($url | url parse | get path | path parse | get extension) {
    "js" | "mjs" | "cjs" => "text/javascript"
    "jsx" => "text/jsx"
    "tsx" => "text/tsx"
    "json" => "application/json"
    "wasm" => "application/wasm"
    _ => "text/typescript"
  }
}
