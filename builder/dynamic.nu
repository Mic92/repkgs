# Shared by the dynamic-derivation producers (fetch-*.nu): they run under builder-rpc-v0 and
# write derivations through `jig nix-store` (worker protocol) instead of fetching anything themselves.

# add a derivation (json on stdin) to the store, returns its .drv path
export def add-drv [name: string, ...refs: string]: record -> string {
  to json --raw | ^jig nix-store add-drv $"($name).drv" ...$refs | str trim
}

# "sha512-<base64> sha1-…" (SRI, possibly several) -> the first as {algo, hex, sri}
export def parse-sri []: string -> record<algo: string, hex: string, sri: string> {
  let sri = ($in | parse -r '^\s*(\S+)' | get capture0.0)
  let parts = ($sri | split row "-" --number 2)
  {algo: $parts.0, hex: ($parts.1 | decode base64 | encode hex --lower), sri: $sri}
}

# fetchurl-drv for an SRI-pinned URL (npm/pnpm locks, locks/go.toml)
export def fetchurl-sri [name: string, url: string, integrity: string]: nothing -> record<drv: string, out: string> {
  let h = ($integrity | parse-sri)
  fetchurl-drv $name $url $h.algo $h.hex $h.sri
}

# fetchurl-drv for a bare sha256 hex digest (jsr, PyPI)
export def fetchurl-sha256 [name: string, url: string, hex: string]: nothing -> record<drv: string, out: string> {
  fetchurl-drv $name $url sha256 $hex $hex
}

# a builtin:fetchurl derivation, identical in shape to what <nix/fetchurl.nix> makes.
# `algo`/`hex` fix the output; `sri` is what goes into outputHash. `name` is made a legal store
# name here (npm scopes bring `@` and `/`), callers refer to the file by the returned `out`
export def fetchurl-drv [wanted_name: string, url: string, algo: string, hex: string, sri: string]: nothing -> record<drv: string, out: string> {
  let name = ($wanted_name | str replace -ar '^\.|[^A-Za-z0-9+._?=-]' '_')
  let out = (^jig nix-store fod-path $name $algo $hex | str trim)
  let drv = ({
    name: $name
    system: "builtin"
    builder: "builtin:fetchurl"
    args: []
    outputs: {out: {path: $out, hashAlgo: $algo, hash: $hex}}
    inputDrvs: {}
    inputSrcs: []
    env: {
      name: $name, out: $out, outputHash: $sri, outputHashAlgo: (if ($sri | str starts-with $"($algo)-") { "" } else { $algo }), outputHashMode: "flat"
      url: $url, urls: $url, executable: "", unpack: ""
      impureEnvVars: "http_proxy https_proxy ftp_proxy all_proxy no_proxy"
      preferLocalBuild: "1", system: "builtin", builder: "builtin:fetchurl"
    }
  } | add-drv $name)
  {drv: $drv, out: $out}
}

# a second producer stage, for locks whose hashes pin metadata that in turn pins the files (jsr):
# `script` (a sibling of this file) runs exactly like the first stage (same environment plus
# `stage_attrs`, the path of a JSON file with `attrs`) once `inputs` (.drv paths) are built. What
# it submits is this producer's result, so nix/fetch.nix unwraps such fetchers with one more outputOf.
export def stage [name: string, script: string, attrs: record, inputs: list<string>]: nothing -> nothing {
  let here = (path self .)
  let drv_name = $"($name).drv"
  let attrs_file = ($attrs | to json --raw | ^jig nix-store add-text $"($name)-attrs.json" | str trim)
  let drv = ({
    name: $drv_name
    system: $env.system
    builder: $"($env.seed)/bin/nu"
    args: [$"($here)/($script)"]
    outputs: {out: {hashAlgo: "t:sha256"}}
    inputDrvs: ($inputs | reduce --fold {} {|d, acc| $acc | insert $d [out] })
    inputSrcs: [$env.seed $env.jig $here $attrs_file]
    env: {
      name: $drv_name, system: $env.system, seed: $env.seed, jig: $env.jig, PATH: $env.PATH
      stage_attrs: $attrs_file, requiredSystemFeatures: "builder-rpc-v0", preferLocalBuild: "1"
      outputHashMode: "text", outputHashAlgo: "sha256"
    }
  } | add-drv $drv_name $env.seed $env.jig $here $attrs_file ...$inputs)
  print -e $"($name): second stage after ($inputs | length) inputs -> ($drv)"
  ^jig nix-store submit $drv out
}

# The collecting derivation, submitted as this producer's output: a floating-CA derivation run by
# the seed's nu that lays out `layout`, a list of
#   {link: <store file>, to: <rel path>}                         symlink
#   {unpack: <tarball>, to: <rel dir>}                            bsdtar --strip-components 1
#   {write: <text>, to: <rel path>}                               literal file (index.json, exports.json, …)
#   {copy: <store file>, append: <text>, to: <rel path>}           the file's bytes with a text trailer (deno's cache format)
# `inputs` are the .drv paths whose outputs `layout` refers to (plus propagated libraries).
export def collect [name: string, layout: list<record<to: string>>, inputs: list<string>]: nothing -> nothing {
  const ASSEMBLE = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    let out = $attrs.outputs.out
    let bin = $"($attrs.seed)/bin"
    for e in $attrs.layout {
      let dst = $"($out)/($e.to)"
      let kind = ($e | columns | first)
      mkdir (if $kind == "unpack" { $dst } else { $dst | path dirname })
      match $kind {
        "link" => { ^$"($bin)/ln" -s $e.link $dst }
        "unpack" => { ^$"($bin)/bsdtar" -xf $e.unpack -C $dst --strip-components 1 --no-same-owner --no-same-permissions }
        "write" => { $e.write | save $dst }
        "copy" => { [(open --raw $e.copy | into binary) ($e.append | into binary)] | bytes collect | save $dst }
      }
    }
    ^$"($bin)/chmod" -R u+w,a-st $out'
  let seed = $env.seed
  let drv = ({
    name: $name
    system: $env.system
    builder: $"($seed)/bin/nu"
    args: ["-c" $ASSEMBLE]
    outputs: {out: {hashAlgo: "r:sha256"}}
    inputDrvs: ($inputs | reduce --fold {} {|d, acc| $acc | insert $d [out] })
    inputSrcs: [$seed]
    env: {__json: ({name: $name, system: $env.system, outputs: [out], seed: $seed, layout: $layout} | to json --raw)}
  } | add-drv $name $seed ...$inputs)
  print -e $"($name): ($layout | length) entries, ($inputs | length) inputs -> ($drv)"
  ^jig nix-store submit $drv out
}

# JSON text for a `write` entry
export def json-file [to: string, value: oneof<record, list<any>>]: nothing -> record<write: string, to: string> { {write: ($value | to json), to: $to} }
