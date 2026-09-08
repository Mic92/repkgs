#!/usr/bin/env nu
# Producer for fetch.cargoVendor { source }: runs under Nix's builder-rpc-v0, reads Cargo.lock out of
# the source tarball and *emits derivations* instead of fetching anything itself:
#   one builtin:fetchurl FOD per registry crate (hash = the lock's checksum, so no hash of ours)
#   one cargo-vendor derivation unpacking them into the layout [source.vendored] wants
# and submits the latter's .drv as this build's output. The consumer depends on
# builtins.outputOf <that> "out". Store writes go through `jig nix-store` (worker protocol).

const CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"

def store-add-drv [name: string, ...refs: string]: record -> string {
  $in | to json -r | ^jig nix-store add-drv $"($name).drv" ...$refs | str trim
}

# builtin:fetchurl derivation for one crate, identical in shape to what <nix/fetchurl.nix> makes
def crate-drv []: record<name: string, version: string, checksum: string> -> record<drv: string, crate: record> {
  let c = $in
  let file = $"($c.name)-($c.version).tar.gz"
  let out = (^jig nix-store fod-path $file sha256 $c.checksum | str trim)
  let drv = ({
    name: $file
    system: "builtin"
    builder: "builtin:fetchurl"
    args: []
    outputs: {out: {path: $out, hashAlgo: "sha256", hash: $c.checksum}}
    inputDrvs: {}
    inputSrcs: []
    env: {
      name: $file, out: $out, outputHash: $c.checksum, outputHashAlgo: "sha256", outputHashMode: "flat"
      url: $"https://static.crates.io/crates/($c.name)/($c.name)-($c.version).crate"
      urls: $"https://static.crates.io/crates/($c.name)/($c.name)-($c.version).crate"
      executable: "", unpack: "", impureEnvVars: "http_proxy https_proxy ftp_proxy all_proxy no_proxy"
      preferLocalBuild: "1", system: "builtin", builder: "builtin:fetchurl"
    }
  } | store-add-drv $file)
  {drv: $drv, crate: {tarball: $out, dir: $"($c.name)-($c.version)", checksum: $c.checksum}}
}

def main []: nothing -> nothing {
  let seed = $env.seed
  ^$"($seed)/bin/bsdtar" -xf $env.source --strip-components 1 "*/Cargo.lock"
  # workspace members have no `source`, everything else must be crates.io
  let packages = (open --raw Cargo.lock | from toml | get package)
  let foreign = ($packages | where {|p| $p.source? != null and $p.source? != $CRATES_IO })
  if ($foreign | is-not-empty) {
    error make {msg: $"cargoVendor: unsupported sources: ($foreign | select name source | to nuon)"}
  }
  let crates = ($packages | where {|p| $p.source? == $CRATES_IO } | each { crate-drv })

  # the vendor derivation: floating CA, so its inputs may be anything and its path is content-defined
  let unpack = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    let out = $attrs.outputs.out
    for c in $attrs.crates {
      mkdir $"($out)/($c.dir)"
      ^$"($attrs.seed)/bin/bsdtar" -xf $c.tarball -C $"($out)/($c.dir)" --strip-components 1
      {files: {}, package: $c.checksum} | to json -r | save $"($out)/($c.dir)/.cargo-checksum.json"
    }'
  let attrs = {name: "cargo-vendor", system: $env.system, outputs: [out], seed: $seed, crates: ($crates | get crate)}
  let vendor = ({
    name: "cargo-vendor"
    system: $env.system
    builder: $"($seed)/bin/nu"
    args: ["-c" $unpack]
    outputs: {out: {hashAlgo: "r:sha256"}}
    inputDrvs: ($crates | reduce --fold {} {|c, acc| $acc | insert $c.drv [out] })
    inputSrcs: [$seed]
    env: {__json: ($attrs | to json --raw)}
  } | store-add-drv "cargo-vendor" $seed ...($crates | get drv))
  print -e $"cargoVendor: ($crates | length) crates -> ($vendor)"
  ^jig nix-store submit $vendor out
}
