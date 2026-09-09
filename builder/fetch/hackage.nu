#!/usr/bin/env nu
# Producer for fetch.hackageSet { locks? }: the set's Haskell version set (locks/hackage.toml,
# `uptrack lock` maintains it) as one directory cabal reads as `repository … url: file+noindex://`,
# <pkg>-<version>.tar.gz with the revised <pkg>-<version>.cabal beside it. Shared by every cabal
# package. Each solves offline against it and builds only its own closure.
use dyn-drv.nu
use ../sys-libs.nu

const HACKAGE = "https://hackage.haskell.org/package"

def main []: nothing -> nothing {
  let table = (open $env.locks | get hackage)
  let files = ($table | items {|name, e|
    let id = $"($name)-($e.version)"
    [
      {to: $"($id).tar.gz", file: $"($id).tar.gz", url: $"($HACKAGE)/($id)/($id).tar.gz", integrity: $e.src}
      {to: $"($id).cabal", file: $"($id)-r($e.rev).cabal", url: $"($HACKAGE)/($id)/revision/($e.rev).cabal", integrity: $e.cabal}
    ]
  } | flatten | dyn-drv fetchurls)
  print -e $"hackageSet: ($table | columns | length) packages"
  let layout = (($files | each {|f| {link: $f.out, to: $f.to} }) | append (dyn-drv json-file exports.json (sys-libs exports hackage-set [])))
  dyn-drv collect hackage-set $layout ($files | get drv)
}
