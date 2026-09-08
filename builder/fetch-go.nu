#!/usr/bin/env nu
# Producer for fetch.goModules { source }: reads go.sum from the source, looks every module
# version up in the repo-wide locks/go.toml (`uptrack lock` writes it: proxy.golang.org .mod/.zip
# sha256, since go.sum's h1: is no file hash), emits one builtin:fetchurl each and a derivation
# laying them out as a GOPROXY=file:// tree (<module>/@v/<version>.{info,mod,zip}). Only this
# package's subset lands in that drv, so edits to the shared table for other packages cut off early.
use dynamic.nu

# module path as the proxy spells it: upper case -> !lower
def escape [m: string]: nothing -> string { $m | str replace -ar "([A-Z])" "!$1" | str downcase }

def sri-hex [sri: string]: nothing -> string { $sri | str replace 'sha256-' '' | decode base64 | encode hex --lower }

def main []: nothing -> nothing {
  let table = (open $env.locks | get go)
  let wanted = (open --raw ([$env.source $env.root go.sum] | path join) | lines | where $it != ""
    | split column " " mod ver | each {|r| $"($r.mod)@($r.ver | str replace '/go.mod' '')" } | uniq)
  let missing = ($wanted | where { $in not-in $table })
  if ($missing | is-not-empty) {
    error make {msg: $"goModules: ($missing | length) modules not in locks/go.toml, run `uptrack lock <pkg>`: ($missing | first 5 | str join ' ')"}
  }
  let files = ($wanted | each {|key|
    let m = ($key | parse -r '^(?<mod>.+)@(?<ver>[^@]+)$' | first)
    let dir = $"(escape $m.mod)/@v"
    $table | get $key | items {|ext, sri|
      let name = $"($m.mod | str replace -ar '[^A-Za-z0-9._-]' '_')-($m.ver).($ext)"
      let d = (dynamic fetchurl-drv $name $"https://proxy.golang.org/($dir)/($m.ver).($ext)" sha256 (sri-hex $sri) $sri)
      {drv: $d.drv, file: {src: $d.out, dst: $"($dir)/($m.ver).($ext)", ver: $m.ver}}
    }
  } | flatten)
  let assemble = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    let out = $attrs.outputs.out
    for f in $attrs.files {
      mkdir ($"($out)/($f.dst)" | path dirname)
      ^$"($attrs.seed)/bin/ln" -s $f.src $"($out)/($f.dst)"
      if ($f.dst | str ends-with ".mod") { {Version: $f.ver} | to json -r | save -f $"($out)/($f.dst | str replace -r ".mod$" ".info")" }
    }'
  dynamic submit go-modules $assemble {files: ($files | get file)} ($files | get drv)
}
