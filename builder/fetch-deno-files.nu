#!/usr/bin/env nu
# Second stage of fetch.denoDeps (after fetch-deno.nu; `stage_attrs` names its {npm, jsr, https}).
# The jsr _meta.json files exist now: each module they list becomes a builtin:fetchurl fixed by
# the manifest's sha256, and the collecting derivation lays out what deno reads under $DENO_DIR:
#   remote/https/<host>[_PORT<n>]/<sha256 of path?query>   module body + "\n// denoCacheMetadata={headers, url}"
#   npm/registry.npmjs.org/<name>/<version>/…              unpacked tarball
#   npm/registry.npmjs.org/<name>/registry.json             packument, cut to the locked versions
use dynamic.nu

const JSR = "https://jsr.io"

def main []: nothing -> nothing {
  let fetched = (open $env.stage_attrs)
  let modules = ($fetched.jsr | each {|p| jsr-modules $p } | flatten)
  print -e $"denoDeps: ($modules | length) jsr modules"

  # everything that goes under remote/: {url, content_type, src | text}
  let remote = [
    ...($modules | select url content_type out | rename -c {out: src})
    ...($fetched.https | insert content_type {|m| content-type $m.url })
    ...($fetched.jsr | each {|p| {url: $p.url, content_type: "application/json", src: $p.meta} })
    ...($fetched.jsr | group-by name | items {|name, versions| version-list $name $versions })
  ]
  let assemble = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    let out = $attrs.outputs.out
    for f in $attrs.remote {
      let u = ($f.url | url parse)
      let dir = $"($out)/remote/($u.scheme)/($u.host)(if $u.port != "" { $"_PORT($u.port)" })"
      let key = ($"($u.path)(if $u.query != "" { $"?($u.query)" })" | hash sha256)
      let body = (if "src" in $f { open --raw $f.src } else { $f.text } | into binary)
      let trailer = ($"\n// denoCacheMetadata=({headers: {content-type: $f.content_type}, url: $f.url} | to json -r)" | into binary)
      mkdir $dir
      [$body $trailer] | bytes collect | save $"($dir)/($key)"
    }
    for p in ($attrs.npm | group-by name | transpose name versions) {
      let dir = $"($out)/npm/registry.npmjs.org/($p.name)"
      for v in $p.versions {
        mkdir $"($dir)/($v.version)"
        ^$"($attrs.seed)/bin/bsdtar" -xf $v.tarball -C $"($dir)/($v.version)" --strip-components 1 --no-same-owner --no-same-permissions
      }
      # "full" and dist.tarball present: deno asks the registry nothing more
      let versions = ($p.versions | each {|v| {$v.version: {version: $v.version, dependencies: {}, dist: {tarball: $v.url, integrity: $v.integrity}}} } | into record)
      {name: $p.name, dist-tags: {}, "_deno.packumentFormat": full, versions: $versions} | to json -r | save $"($dir)/registry.json"
    }
    ^$"($attrs.seed)/bin/chmod" -R u+w,a-st $out'
  dynamic submit deno-deps $assemble {remote: $remote, npm: $fetched.npm} ($modules | get drv)
}

# the loadable modules of one jsr package version: {url, content_type, drv, out}. jsr's publish-time
# module graph names them; test data, docs and CI files in the manifest are not fetched
def jsr-modules [p: record]: nothing -> table {
  let meta = (open --raw $p.meta | from json)
  let graph = ($meta.moduleGraph2? | default $meta.moduleGraph1? | default {})
  $meta.manifest | transpose path file | where {|m| $graph has $m.path } | each {|m|
    let url = $"($JSR)/($p.name)/($p.version)($m.path)"
    let store_name = ($"jsr-($p.name)-($p.version)($m.path)" | str replace -ar '[^A-Za-z0-9._-]' "_")
    {url: $url, content_type: (content-type $url)}
      | merge (dynamic fetchurl-sha256 $store_name $url ($m.file.checksum | str replace "sha256-" ""))
  }
}

# @scope/name/meta.json: deno only checks that the locked versions are listed
def version-list [name: string, versions: list<record>]: nothing -> record {
  let listed = ($versions | each {|v| {$v.version: {}} } | into record)
  {url: $"($JSR)/($name)/meta.json", content_type: "application/json", text: ({versions: $listed} | to json -r)}
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
