# exports.json: what a package offers dependents (include, lib, pkgconfig, aclocal dirs relative
# to its root, libs, env, propagate), read with defaults from the tree and written by finish.
# env.nu turns the closure of these into search paths

use glob.nu [files]
use names.nu [linkable-libs]

def existing [root: path, rels: list<string>]: nothing -> list<string> { $rels | where {|d| $"($root)/($d)" | path exists } }

# a package's exports with defaults filled in. Used for dependencies and for writing our own
export def exports-of [p: path]: nothing -> record<name: string, includeDirs: list<string>, libDirs: list<string>, libs: list<string>, pkgconfigDirs: list<string>, aclocalDirs: list<string>, env: record, propagate: list<string>, dllDirs: list<string>> {
  let f = $"($p)/exports.json"
  let e = if ($f | path exists) { open $f } else { {} }
  let expand = {|s| $s | str replace -a "{root}" $p | str replace -a "{store}" ($p | path dirname) }
  {
    # package name as build systems key on it (sys-libs.nu, dep-root); the store name is <hash>-<name>[-<platform>]
    name: ($e.name? | default { $p | path basename | str substring 33.. | str replace -r '-(x86_64|aarch64|riscv64|loongarch64|powerpc64le)-[\w-]+$' '' })
    includeDirs: ($e.includeDirs? | default { existing $p ["include"] })
    libDirs: ($e.libDirs? | default { existing $p ["lib"] })
    libs: ($e.libs? | default [])
    pkgconfigDirs: ($e.pkgconfigDirs? | default { existing $p ["lib/pkgconfig" "share/pkgconfig"] })
    aclocalDirs: ($e.aclocalDirs? | default { existing $p ["share/aclocal"] })
    # `{root}` in values: this package's own store path (kept relative in exports.json so the output stays relocatable)
    env: ($e.env? | default {} | items {|k, v| [$k (do $expand $v)] } | into record)
    propagate: ($e.propagate? | default [])
    # PE: what RUNPATH would record (builder/launchers.nu)
    dllDirs: ($e.dllDirs? | default [] | each { do $expand $in })
  }
}

# dependencies plus everything they `propagate`, breadth first, each once
export def dep-closure [roots: list<string>]: nothing -> list<record> {
  mut done = []
  mut todo = $roots
  while ($todo | is-not-empty) {
    let p = ($todo | first)
    $todo = ($todo | skip 1)
    if $p in ($done | get root) { continue }
    let d = (exports-of $p | insert root $p)
    $done ++= [$d]
    $todo ++= $d.propagate
  }
  $done
}


# absolute directories of one exports field (libDirs, includeDirs, …) across dependencies
export def dep-dirs [deps: list<record<name: string, root: string>>, field: string]: nothing -> list<string> {
  $deps | each {|d| $d | get $field | each {|rel| $"($d.root)/($rel)" } } | flatten
}

# exports.json: spec.exports over the defaults, exports = false: nothing to link against
export def write-exports [out: string, spec: record, platform: record, deps: list<record>]: nothing -> nothing {
  let none = {includeDirs: [], libDirs: [], libs: [], pkgconfigDirs: [], aclocalDirs: []}
  let own = (if $spec.exports? == false { $none } else { $spec.exports? | default {} })
  let exports = (exports-of $out | upsert libs (linkable-libs $platform $"($out)/lib") | merge $own | upsert name $spec.name)
  let exports = ($exports | update propagate { $in ++ (required-deps $out $deps $exports) | uniq })
  let rel = {|s| $s | str replace -a $out "{root}" | str replace -a $env.NIX_STORE "{store}" }
  let exports = (if ($exports.dllDirs | is-empty) { $exports | reject dllDirs } else { $exports | update dllDirs { each { do $rel $in } } })
  $exports | to json | save -f $"($out)/exports.json"
}

# dependencies our .pc files (Requires) and cmake configs (find_dependency) name: a consumer
# needs those on its search paths too. Names no dependency provides are optional backends
# (curl: GnuTLS) or our own sibling .pc files
def required-deps [out: string, deps: list<record>, exports: record]: nothing -> list<string> {
  let grep = {|glob, re| files $glob | each {|f| open --raw $f | parse -r $re | get r } | flatten }
  let pc = ($exports.pkgconfigDirs | each {|d| do $grep $"($out)/($d)/*.pc" '(?m)^Requires(?:\.private)?:[ \t]*(?<r>.*)' } | flatten
    | split row -r '[,\s]+' | where { $in =~ '^[A-Za-z_][\w.+-]*$' } | each { $"($in).pc" | str lowercase })
  let cm = (do $grep $"($out)/lib/cmake/**/*.cmake" 'find_dependency\s*\(\s*(?<r>[\w-]+)' | str lowercase)
  let roots = ($deps.root | where { $in != $out })
  if ($roots | is-empty) or ($pc ++ $cm | is-empty) { return [] }
  # <dep>/{lib,share}/pkgconfig/<name>.pc and <dep>/{lib,share}/cmake/<Name>, one find over all deps
  let provided = (^find ...$roots -mindepth 3 -maxdepth 3 "(" -path "*/pkgconfig/*.pc" -o -path "*/cmake/*" ")" | lines
    | each {|p| {name: ($p | path basename | str lowercase), root: ($p | path dirname -n 3)} })
  $provided | where name in ($pc ++ $cm) | get root | uniq | sort
}
