#!/usr/bin/env nu
# Producer for fetch.luaRocksSet { locks? }: the set's rock versions (locks/luarocks.toml, `uptrack
# lock` maintains it) as a directory luarocks reads as a rocks server: <name>-<version>.src.rock
# files plus the manifest-<lua major.minor> naming exactly those. One version per rock, so `luarocks make` against it
# resolves every range to the locked version or fails loudly.
use dyn-drv.nu
use ../sys-libs.nu

const LUAROCKS = "https://luarocks.org"

def main []: nothing -> nothing {
  let table = (open $env.locks | get luarocks)
  let files = ($table | items {|name, e|
    let file = $"($name)-($e.version).src.rock"
    {to: $file, file: $file, url: $"($LUAROCKS)/($file)", integrity: $e.sha256}
  } | dyn-drv fetchurls)
  let manifest = ([
    "commands = {}"
    "modules = {}"
    "repository = {"
    ...($table | items {|name, e| $"   [\"($name)\"] = { [\"($e.version)\"] = { { arch = \"src\" } } }," })
    "}"
  ] | str join "
")
  print -e $"luaRocksSet: ($table | columns | length) rocks"
  let layout = [
    ...($files | each {|f| {link: $f.out, to: $f.to} })
    {write: $manifest, to: $"manifest-($env.luaVersion | split row "." | take 2 | str join ".")"}
    (dyn-drv json-file exports.json (sys-libs exports luarocks-set []))
  ]
  dyn-drv collect luarocks-set $layout ($files | get drv)
}
