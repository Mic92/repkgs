#!/usr/bin/env nu
# Producer for fetch.npmDeps { source, root?, lockFile? }: like cargo-vendor-drv.nu, but for a
# package-lock.json (v2/v3). Every registry package there has `resolved` (tarball URL) and
# `integrity` (SRI, usually sha512), so each becomes a builtin:fetchurl derivation fixed by that
# very hash. The collector derivation writes a directory of
#   tarballs/<n>.tgz -> store path      (symlinks, so npm sees file: URLs)
#   package-lock.json                   (`resolved` rewritten to those file: URLs)
# npm.nu copies that lock over the source's and runs `npm ci --offline`. npm verifies `integrity`
# itself, no cacache needs to be synthesised.

def store-add-drv [name: string, ...refs: string]: record -> string {
  $in | to json --raw | ^jig nix-store add-drv $"($name).drv" ...$refs | str trim
}

# "sha512-<base64>" -> {algo, hex}
def parse-sri []: string -> record<algo: string, hex: string> {
  let sri = ($in | split row " " | first)  # may list several, strongest first is npm's habit
  let parts = ($sri | split row "-" --number 2)
  {algo: $parts.0, hex: ($parts.1 | decode base64 | encode hex --lower)}
}

# store file name for a tarball URL: last path segment, scoped packages keep readable names
def tarball-name []: string -> string {
  $in | url parse | get path | path basename
}

def fetch-drv [url: string, sri: string]: nothing -> record<drv: string, out: string> {
  let name = ($url | tarball-name)
  let h = ($sri | parse-sri)
  let out = (^jig nix-store fod-path $name $h.algo $h.hex | str trim)
  let drv = ({
    name: $name
    system: "builtin"
    builder: "builtin:fetchurl"
    args: []
    outputs: {out: {path: $out, hashAlgo: $h.algo, hash: $h.hex}}
    inputDrvs: {}
    inputSrcs: []
    env: {
      name: $name, out: $out, outputHash: $sri, outputHashAlgo: "", outputHashMode: "flat"
      url: $url, urls: $url, executable: "", unpack: ""
      impureEnvVars: "http_proxy https_proxy ftp_proxy all_proxy no_proxy"
      preferLocalBuild: "1", system: "builtin", builder: "builtin:fetchurl"
    }
  } | store-add-drv $name)
  {drv: $drv, out: $out}
}

def main []: nothing -> nothing {
  let seed = $env.seed
  let lock_rel = ([$env.root package-lock.json] | path join)
  cp (if ($env.lockFile? | default "") != "" { $env.lockFile } else { $"($env.source)/($lock_rel)" }) package-lock.json
  let lock = (open package-lock.json)
  if ($lock.lockfileVersion? | default 1) < 2 {
    error make {msg: "npmDeps: package-lock.json v1 is not supported (run `npm i --lockfile-version 3`)"}
  }
  let entries = ($lock.packages | transpose key val | where key != "")
  let foreign = ($entries | where {|e|
    let r = ($e.val.resolved? | default "")
    $r != "" and not ($r starts-with "https://") and not ($r starts-with "http://")
  })
  if ($foreign | is-not-empty) {
    error make {msg: $"npmDeps: unsupported `resolved` (git/file) for: ($foreign | get key | str join ', ')"}
  }
  # workspace links and bundled deps have no `resolved`. Everything fetched needs `integrity`
  let remote = ($entries | where {|e| ($e.val.resolved? | default "") != "" })
  let unhashed = ($remote | where {|e| ($e.val.integrity? | default "") == "" })
  if ($unhashed | is-not-empty) {
    error make {msg: $"npmDeps: no `integrity` for: ($unhashed | get key | str join ', ')"}
  }
  # the same tarball can appear under several node_modules paths: fetch once per URL
  let fetched = ($remote | each {|e| {url: $e.val.resolved, sri: $e.val.integrity} } | uniq-by url
    | each {|f| {url: $f.url} | merge (fetch-drv $f.url $f.sri) })
  let by_url = ($fetched | reduce --fold {} {|f, acc| $acc | insert $f.url $f.out })
  let new_lock = ($lock | update packages {|l|
    $l.packages | items {|key, val|
      let r = ($val.resolved? | default "")
      {$key: (if $r == "" { $val } else { $val | update resolved $"file:($by_url | get $r)" })}
    } | reduce {|it| merge $it }
  } | reject --optional dependencies)

  # structured attrs: the lock is far beyond execve's env limit, and it is typed data anyway
  let collect = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    mkdir $attrs.outputs.out
    $attrs.lock | to json | save $"($attrs.outputs.out)/package-lock.json"'
  let attrs = {name: "npm-deps", system: $env.system, outputs: [out], lock: $new_lock}
  let drv = ({
    name: "npm-deps"
    system: $env.system
    builder: $"($seed)/bin/nu"
    args: ["-c" $collect]
    outputs: {out: {hashAlgo: "r:sha256"}}
    # the tarballs are inputs so the lock's file: paths are realised (and GC-rooted) with it
    inputDrvs: ($fetched | reduce --fold {} {|f, acc| $acc | insert $f.drv [out] })
    inputSrcs: [$seed]
    env: {__json: ($attrs | to json --raw)}
  } | store-add-drv "npm-deps" $seed ...($fetched | get drv))
  print --stderr $"npmDeps: ($fetched | length) tarballs -> ($drv)"
  ^jig nix-store submit $drv out
}
