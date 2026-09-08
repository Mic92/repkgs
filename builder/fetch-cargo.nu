#!/usr/bin/env nu
# Producer for fetch.cargoVendor { source }: reads Cargo.lock from the source and emits one
# builtin:fetchurl per registry crate (hash = the lock's checksum, so no hash of ours) plus a
# cargo-vendor derivation unpacking them into the layout [source.vendored] wants.
use dynamic.nu

const CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"

def main []: nothing -> nothing {
  # workspace members have no `source`, everything else must be crates.io
  let packages = (open --raw $"($env.source)/Cargo.lock" | from toml | get package)
  let foreign = ($packages | where {|p| $p.source? != null and $p.source? != $CRATES_IO })
  if ($foreign | is-not-empty) {
    error make {msg: $"cargoVendor: unsupported sources: ($foreign | select name source | to nuon)"}
  }
  let crates = ($packages | where {|p| $p.source? == $CRATES_IO } | each {|c|
    let file = $"($c.name)-($c.version).tar.gz"
    let f = (dynamic fetchurl-drv $file $"https://static.crates.io/crates/($c.name)/($c.name)-($c.version).crate" sha256 $c.checksum $c.checksum)
    {drv: $f.drv, crate: {tarball: $f.out, dir: $"($c.name)-($c.version)", checksum: $c.checksum}}
  })
  let unpack = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    let out = $attrs.outputs.out
    for c in $attrs.crates {
      mkdir $"($out)/($c.dir)"
      ^$"($attrs.seed)/bin/bsdtar" -xf $c.tarball -C $"($out)/($c.dir)" --strip-components 1
      {files: {}, package: $c.checksum} | to json -r | save $"($out)/($c.dir)/.cargo-checksum.json"
    }'
  dynamic submit cargo-vendor $unpack {crates: ($crates | get crate)} ($crates | get drv)
}
