#!/usr/bin/env nu
# Producer for fetch.cargoVendor { source }: reads Cargo.lock from the source and emits one
# builtin:fetchurl per registry crate (hash = the lock's checksum, so no hash of ours) plus a
# cargo-vendor derivation unpacking them into the layout [source.vendored] wants.
use dyn-drv.nu

const CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"

def main []: nothing -> nothing {
  let v = (vendor-layout (open --raw $"($env.source)/Cargo.lock") "")
  dyn-drv collect cargo-vendor $v.layout $v.drvs
}

# fetchurl derivations plus collect layout for one Cargo.lock, under `prefix`/ (fetch/pypi-vendor.nu
# puts several side by side). Workspace members have no `source`, everything else must be crates.io
export def vendor-layout [lock: string, prefix: string]: nothing -> record<layout: list<any>, drvs: list<string>> {
  let packages = ($lock | from toml | get package)
  let foreign = ($packages | where {|p| $p.source? != null and $p.source? != $CRATES_IO })
  if ($foreign | is-not-empty) {
    error make {msg: $"cargoVendor: unsupported sources: ($foreign | select name source | to nuon)"}
  }
  let crates = ($packages | where {|p| $p.source? == $CRATES_IO } | each {|c|
    {dir: $"($prefix)($c.name)-($c.version)", checksum: $c.checksum, file: $"($c.name)-($c.version).tar.gz"
      url: $"https://static.crates.io/crates/($c.name)/($c.name)-($c.version).crate", sha256: $c.checksum}
  } | dyn-drv fetchurls)
  let layout = ($crates | each {|c| [{unpack: $c.out, to: $c.dir} (dyn-drv json-file $"($c.dir)/.cargo-checksum.json" {files: {}, package: $c.checksum})] } | flatten)
  {layout: $layout, drvs: ($crates | get -o drv | default [])}
}
