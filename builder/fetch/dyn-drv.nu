# Shared by the dynamic-derivation producers (its siblings in fetch/): they run under builder-rpc-v0 and
# write derivations through `jig nix-store` (worker protocol) instead of fetching anything themselves.

# add a derivation (json on stdin) to the store, returns its .drv path
export def add-drv [name: string, ...refs: string]: record -> string {
  to json --raw | ^jig nix-store add-drv $"($name).drv" ...$refs | str trim
}

# "sha512-<base64> sha1-…" (SRI, possibly several) -> the first as {algo, hex, sri}
def parse-sri []: string -> record<algo: string, hex: string, sri: string> {
  let sri = ($in | parse -r '^\s*(\S+)' | get capture0.0)
  let parts = ($sri | split row "-" --number 2)
  {algo: $parts.0, hex: ($parts.1 | decode base64 | encode hex --lower), sri: $sri}
}

# One builtin:fetchurl derivation per row, made in a single `jig nix-store fetchurls` call. Rows
# carry `file` (store name, sanitised here), `url` and `integrity` (SRI) or `sha256` (hex);
# other columns are kept, `drv` and `out` added.
export def fetchurls []: table -> table {
  let rows = $in
  if ($rows | is-empty) { return [] }
  let req = ($rows | each {|r|
    let h = (if $r.integrity? != null { $r.integrity | parse-sri } else { {algo: sha256, hex: ($r.sha256 | str downcase), sri: $r.sha256} })
    {name: ($r.file | str replace -ar '^\.|[^A-Za-z0-9+._?=-]' '_'), url: $r.url} | merge $h
  })
  let made = ($req | to json --raw | ^jig nix-store fetchurls | from json)
  $rows | merge ($made | select drv out)
}

# a second producer stage, for locks whose hashes pin metadata that in turn pins the files (jsr):
# `script` (a sibling of this file) runs exactly like the first stage (same environment plus
# `stage_attrs`, the path of a JSON file with `attrs`) once `inputs` (.drv paths) are built. What
# it submits is this producer's result, so nix/fetch.nix unwraps such fetchers with one more outputOf.
export def stage [name: string, script: string, attrs: record, inputs: list<string>]: nothing -> nothing {
  const here = path self .
  let producers = ($here | path dirname)  # the store path; fetch/ is a directory inside it
  let drv_name = $"($name).drv"
  let attrs_file = ($attrs | to json --raw | ^jig nix-store add-text $"($name)-attrs.json" | str trim)
  let drv = ({
    name: $drv_name
    system: $env.system
    builder: $"($env.seed)/bin/nu"
    args: [$"($here)/($script)"]
    outputs: {out: {hashAlgo: "text:sha256"}}
    inputDrvs: ($inputs | each {|d| [$d [out]] } | into record)
    inputSrcs: [$env.seed $env.jig $producers $attrs_file]
    env: {
      name: $drv_name, system: $env.system, seed: $env.seed, jig: $env.jig, PATH: ($env.PATH | str join ":")
      stage_attrs: $attrs_file, requiredSystemFeatures: "builder-rpc-v0", preferLocalBuild: "1"
      outputHashMode: "text", outputHashAlgo: "sha256"
    }
  } | add-drv $drv_name $env.seed $env.jig $producers $attrs_file ...$inputs)
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
# `--script`: a sibling of this file to run instead, with `attrs` as structured attrs, for
# outputs that are not a plain layout (winsdk-assemble.nu unpacks msi and vsix)
export def collect [name: string, layout: list<record<to: string>>, inputs: list<string>, --script: string, --attrs: record = {}]: nothing -> nothing {
  const ASSEMBLE = '
    let attrs = (open $env.NIX_ATTRS_JSON_FILE)
    let out = $attrs.outputs.out
    let bin = $"($attrs.seed)/bin"
    $attrs.layout | par-each --threads ($env.NIX_BUILD_CORES? | default "4" | into int) {|e|
      let dst = $"($out)/($e.to)"
      let kind = ([link unpack write copy] | where {|k| $k in ($e | columns) } | first)
      mkdir (if $kind == "unpack" { $dst } else { $dst | path dirname })
      match $kind {
        "link" => { ^$"($bin)/ln" -s $e.link $dst }
        "unpack" => { ^$"($bin)/bsdtar" -xf $e.unpack -C $dst --strip-components 1 --no-same-owner --no-same-permissions }
        "write" => { $e.write | save $dst }
        "copy" => { [(open --raw $e.copy | into binary) ($e.append | into binary)] | bytes collect | save $dst }
      }
    } | ignore
    ^$"($bin)/chmod" -R u+w,go-w,a-st $out'
  const here = path self .
  let seed = $env.seed
  let srcs = ([$seed] ++ (if $script == null { [] } else { [($here | path dirname)] }))
  let drv = ({
    name: $name
    system: $env.system
    builder: $"($seed)/bin/nu"
    args: (if $script == null { ["-c" $ASSEMBLE] } else { [$"($here)/($script)"] })
    outputs: {out: {hashAlgo: "r:sha256"}}
    inputDrvs: ($inputs | each {|d| [$d [out]] } | into record)
    inputSrcs: $srcs
    env: {__json: ({name: $name, system: $env.system, outputs: [out], seed: $seed, layout: $layout} | merge $attrs | to json --raw)}
  } | add-drv $name ...$srcs ...$inputs)
  print -e $"($name): ($layout | length) entries, ($inputs | length) inputs -> ($drv)"
  ^jig nix-store submit $drv out
}

# JSON text for a `write` entry
export def json-file [to: string, value: oneof<record, list<any>>]: nothing -> record<write: string, to: string> { {write: ($value | to json), to: $to} }
