#!/usr/bin/env nu
# Producer for fetch.goModules { source, root?, locks?, libs? }.
#
# go.sum names every module version but its h1: hashes are over a file tree, not a file, so the
# .mod/.zip sha256s come from the repo-wide locks/go.toml (`uptrack lock` fills it from
# proxy.golang.org). Each becomes a builtin:fetchurl; the output lays this package's subset out as
# a GOPROXY=file:// tree, <module>/@v/<version>.{info,mod,zip}, plus exports.json propagating the
# libraries cgo modules in the lock link (sys-libs.nu). Edits to the shared table that do not touch
# this package's modules leave the output unchanged.
use dyn-drv.nu
use ../sys-libs.nu

const PROXY = "https://proxy.golang.org"

def main []: nothing -> nothing {
  let table = (open $env.locks | get go)
  let modules = (go-sum ([$env.source $env.root go.sum] | path join))
  let missing = ($modules | where {|m| $table not-has $m.key })
  if ($missing | is-not-empty) {
    error make {msg: $"goModules: ($missing | length) modules not in locks/go.toml \(`uptrack lock <pkg>` adds them): ($missing | get key | first 5 | str join ' ')"}
  }
  let libs = (sys-libs pick go ($modules | get path | uniq) $env.sysLibs)

  # .mod and .zip for each module version, plus the <version>.info the proxy protocol also wants
  let files = ($modules | each {|m|
    let dir = $"(proxy-case $m.path)/@v"
    $table | get $m.key | items {|ext, sri|
      let file = $"($m.version).($ext)"
      {to: $"($dir)/($file)", file: $"($m.path)-($file)", url: $"($PROXY)/($dir)/($file)", integrity: $sri}
    }
  } | flatten | dyn-drv fetchurls)
  let layout = [
    ...($files | each {|f| {link: $f.out, to: $f.to} })
    ...($modules | each {|m| dyn-drv json-file $"(proxy-case $m.path)/@v/($m.version).info" {Version: $m.version} })
    (dyn-drv json-file exports.json (sys-libs exports go-modules $libs))
  ]
  dyn-drv collect go-modules $layout (($files | get drv) ++ ($libs | get -o drv | default []))
}

# [{key: "path@version", path, version}], one per module version (go.sum lists most twice: tree and /go.mod)
def go-sum [file: path]: nothing -> table {
  open --raw $file | lines | where $it != "" | split column " " path version
    | update version { str replace "/go.mod" "" }
    | uniq-by path version
    | insert key {|m| $"($m.path)@($m.version)" }
}

# the proxy's case encoding for module paths: "github.com/BurntSushi" -> "github.com/!burnt!sushi"
def proxy-case [path: string]: nothing -> string { $path | str replace -ar "([A-Z])" "!$1" | str lowercase }
