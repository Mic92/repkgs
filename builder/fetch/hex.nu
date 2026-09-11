#!/usr/bin/env nu
# Producer for fetch.hexDeps { source, root? }: mix.lock or rebar.lock -> one builtin:fetchurl
# per package (both locks carry repo.hex.pm's outer tarball sha256), laid out as Hex's cache:
# packages/hexpm/<name>-<version>.tar
use dyn-drv.nu

const REPO = "https://repo.hex.pm/tarballs"

def main []: nothing -> nothing {
  let dir = ([$env.source $env.root] | path join)
  let pkgs = (if ($"($dir)/mix.lock" | path exists) { mix-lock (open --raw $"($dir)/mix.lock") } else { rebar-lock (open --raw $"($dir)/rebar.lock") })
  let fetched = ($pkgs | each {|p|
    let file = $"($p.name)-($p.version).tar"
    {file: $file, url: $"($REPO)/($file)", sha256: $p.sha256}
  } | dyn-drv fetchurls)
  dyn-drv collect hex-deps ($fetched | each {|f| {link: $f.out, to: $"packages/hexpm/($f.file)"} }) ($fetched | get drv)
}

# "app": {:hex, :name, "version", "inner", [tools], [deps], "hexpm", "outer"}
def mix-lock [text: string]: nothing -> table<name: string, version: string, sha256: string> {
  let hex = ($text | parse -r '\{:hex, :(?<name>\w+), "(?<version>[^"]+)", "[0-9a-f]{64}",.*?"hexpm", "(?<sha256>[0-9a-f]{64})"\}')
  let foreign = ($text | parse -r '"(?<app>\w+)": \{:(?<scm>git|path)\b')
  if ($foreign | is-not-empty) { error make {msg: $"hexDeps: mix.lock has non-hex entries: ($foreign | get app | str join ', ')"} }
  $hex
}

# {<<"name">>,{pkg,<<"name">>,<<"version">>},_} in the first term, {<<"name">>, <<"SHA">>} under pkg_hash_ext
def rebar-lock [text: string]: nothing -> table<name: string, version: string, sha256: string> {
  let pkgs = ($text | parse -r '\{pkg,<<"(?<name>[^"]+)">>,<<"(?<version>[^"]+)">>' )
  let ext = ($text | parse -r '(?s)\{pkg_hash_ext,\[(?<body>.*?)\]\}' | get -o body.0 | default "")
  let hashes = ($ext | parse -r '\{<<"(?<name>[^"]+)">>, <<"(?<sha256>[0-9A-F]{64})">>\}' | update sha256 { str lowercase })
  let foreign = ($text | parse -r '\{<<"(?<name>[^"]+)">>,\{(?<scm>git|hg|path)\b')
  if ($foreign | is-not-empty) { error make {msg: $"hexDeps: rebar.lock has non-hex entries: ($foreign | get name | str join ', ')"} }
  $pkgs | join $hashes name | select name version sha256
}
