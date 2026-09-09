#!/usr/bin/env nu
# Producer for fetch.gems { source, root?, lockFile?, libs? }.
#
# Gemfile.lock's CHECKSUMS section (Bundler >= 2.6, `bundle lock --add-checksums`) lists
#   name (version[-platform]) sha256=<hex>
# per gem. Pure-ruby gems and those prebuilt for our platform become builtin:fetchurl derivations
# from rubygems.org. Output: { vendor/cache/*.gem, Gemfile.lock, exports.json }, which is what
# `bundle install --local` reads (builder/bundler.nu); exports.json propagates the libraries the
# locked gems link (sys-libs.nu). `lockFile` is for upstreams that commit no Gemfile.lock.
use dynamic.nu
use sys-libs.nu

const RUBYGEMS = "https://rubygems.org/gems"

def main []: nothing -> nothing {
  let lock_file = (if $env.lockFile != "" { $env.lockFile } else { [$env.source $env.root Gemfile.lock] | path join })
  let lock = (open --raw $lock_file)
  let gems = (checksums $lock)
  # bundler installs the platform gem when both it and the ruby one are cached, so ship both
  let ours = ($gems | where platform in ["" $env.gemPlatform $"($env.gemPlatform)-gnu"])
  let libs = (sys-libs pick gems ($gems | get name | uniq) $env.sysLibs)

  let fetched = ($ours | each {|gem|
    let file = $"($gem.name)-($gem.version)(if $gem.platform != "" { $"-($gem.platform)" }).gem"
    {file: $file} | merge (dynamic fetchurl-drv $file $"($RUBYGEMS)/($file)" sha256 $gem.sha256 $gem.sha256)
  })
  let layout = [
    ...($fetched | each {|g| {link: $g.out, to: $"vendor/cache/($g.file)"} })
    {write: $lock, to: "Gemfile.lock"}
    (dynamic json-file exports.json (sys-libs exports gems $libs))
  ]
  dynamic collect gems $layout (($fetched | get drv) ++ ($libs | get -o drv | default []))
}

# [{name, version, platform, sha256}] from the CHECKSUMS section; the application's own PATH gem
# is listed there without a checksum and dropped
def checksums [lock: string]: nothing -> table {
  # sections are "NAME\n  line…" blocks separated by blank lines
  let section = ($lock | parse -r '(?s)\nCHECKSUMS\n(?<body>.*?)(?:\n\n|$)' | get -o body.0)
  if $section == null {
    error make {msg: "gems: Gemfile.lock has no CHECKSUMS section; `uptrack lock <pkg>` adds one (bundle lock --add-checksums)"}
  }
  $section | lines
    | parse -r '^  (?<name>\S+) \((?<version>[^)-]+)(?:-(?<platform>[^)]+))?\)(?: sha256=(?<sha256>[0-9a-f]{64}))?$'
    | where sha256 != ""
}
