# Shared by the dynamic-derivation producers (fetch-cargo.nu, fetch-npm.nu): they run under
# builder-rpc-v0 and write derivations through `jig nix-store` (worker protocol) instead of
# fetching anything themselves.

# add a derivation (json on stdin) to the store, returns its .drv path
export def add-drv [name: string, ...refs: string]: record -> string {
  to json --raw | ^jig nix-store add-drv $"($name).drv" ...$refs | str trim
}

# "sha512-<base64> sha1-…" (SRI, possibly several) -> the first as {algo, hex, sri}
export def parse-sri []: string -> record<algo: string, hex: string, sri: string> {
  let sri = ($in | split row " " | first)
  let parts = ($sri | split row "-" --number 2)
  {algo: $parts.0, hex: ($parts.1 | decode base64 | encode hex --lower), sri: $sri}
}

# fetchurl-drv for an SRI-pinned URL (npm/pnpm locks, locks/go.toml)
export def fetchurl-sri [name: string, url: string, integrity: string]: nothing -> record<drv: string, out: string> {
  let h = ($integrity | parse-sri)
  fetchurl-drv $name $url $h.algo $h.hex $h.sri
}

# a builtin:fetchurl derivation, identical in shape to what <nix/fetchurl.nix> makes.
# `algo`/`hex` fix the output; `sri` is what goes into outputHash
export def fetchurl-drv [name: string, url: string, algo: string, hex: string, sri: string]: nothing -> record<drv: string, out: string> {
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

# the collecting derivation: a nu script run by the seed with structured attrs, floating CA so its
# path is content-defined. Submitted as this producer's output
export def submit [name: string, script: string, attrs: record, inputs: list<string>]: nothing -> nothing {
  let seed = $env.seed
  let drv = ({
    name: $name
    system: $env.system
    builder: $"($seed)/bin/nu"
    args: ["-c" $script]
    outputs: {out: {hashAlgo: "r:sha256"}}
    inputDrvs: ($inputs | reduce --fold {} {|d, acc| $acc | insert $d [out] })
    inputSrcs: [$seed]
    env: {__json: ({name: $name, system: $env.system, outputs: [out], seed: $seed} | merge $attrs | to json --raw)}
  } | add-drv $name $seed ...$inputs)
  print -e $"($name): ($inputs | length) inputs -> ($drv)"
  ^jig nix-store submit $drv out
}
