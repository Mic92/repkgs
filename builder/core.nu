# The package builder's shared vocabulary. nix/package.nix generates, per package, the script
#   use core.nu *; use prepare.nu; use finish.nu; use <bs>.nu …; prepare; <bs> setup …; <steps> …; finish
# which runs in one nu process, so `def --env` verbs hand cwd and environment on to later steps.
# This module is what build systems and custom steps import: ctx, knobs, x, tool, note, exports-of.

# One log line per event, in Nix's own structured-log form ("@nix {json}", libutil/logging.cc) so
# `nix build`/nom show the current phase and `nix log` keeps the text. `step` events become the
# derivation's phase, everything else an info-level message. nix/package.nix emits one per step
export def note [step: string, msg: string = ""]: nothing -> nothing {
  let ev = if $step == "step" { {action: setPhase, phase: $msg} } else { {action: msg, level: 3, msg: $"($step): ($msg)"} }
  print -e $"@nix ($ev | to json -r)"
}

# what build-system verbs and custom steps get to see: {spec out deps njobs src build platform testsRun}
export def ctx []: nothing -> record<spec: record, out: string, deps: list<record>, njobs: int, src: string, build: string, platform: record, testsRun: bool, cache: bool> { $env.PKGS_CTX | from json }

# a build system's knobs: its defaults overridden by the package's `<bs>.*` attrset
export def knobs-for [bs: string, defaults: record]: nothing -> record { $defaults | merge ((ctx).spec | get -o $bs | default {}) }

# run an external, echoing the command line first (the build log is the `set -x` of this tree)
export def --wrapped x [cmd: string, ...args: string]: nothing -> nothing {
  print -e $"+ ($cmd) ($args | str join ' ')"
  ^$cmd ...$args
}

# absolute path of a tool on PATH
export def tool [name: string]: nothing -> path {
  let hits = (which $name)
  if ($hits | is-empty) { error make {msg: $"($name) not on PATH"} }
  $hits | first | get path
}

# the derivation's structured attrs (nix/package.nix `common`)
export def attrs []: nothing -> record { open $env.NIX_ATTRS_JSON_FILE }

export def is-elf [f: path]: nothing -> bool { (open --raw $f | into binary | bytes at 0..<4) == 0x[7f 45 4c 46] }

def existing [root: path, rels: list<string>]: nothing -> list<string> { $rels | where {|d| $"($root)/($d)" | path exists } }

# a package's exports with defaults filled in. Used for dependencies and for writing our own
export def exports-of [p: path]: nothing -> record<includeDirs: list<string>, libDirs: list<string>, libs: list<string>, pkgconfigDirs: list<string>, aclocalDirs: list<string>, env: record, propagate: list<string>> {
  let f = $"($p)/exports.json"
  let e = if ($f | path exists) { open $f } else { {} }
  {
    includeDirs: ($e.includeDirs? | default (existing $p ["include"]))
    libDirs: ($e.libDirs? | default (existing $p ["lib"]))
    libs: ($e.libs? | default (glob $"($p)/lib/lib*.so" | each { path parse | get stem | str substring 3.. } | sort))
    pkgconfigDirs: ($e.pkgconfigDirs? | default (existing $p ["lib/pkgconfig" "share/pkgconfig"]))
    aclocalDirs: ($e.aclocalDirs? | default (existing $p ["share/aclocal"]))
    env: ($e.env? | default {})
    propagate: ($e.propagate? | default [])
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

# store path -> launcher template relative to the package ({root}/..., {store}/<basename>/...)
export def storerel [p: string, out: string]: nothing -> string {
  let store = $"($env.NIX_STORE)/"
  if ($p | str starts-with $out) { $"{root}($p | str substring ($out | str length)..)" } else if ($p | str starts-with $store) { $"{store}/($p | str substring ($store | str length)..)" } else { $p }
}

# key = kind + every explicit input of the probes: the script that defines them, the masked
# toolchain/dependency/tool set, platform, flags. $out is the fixed CA placeholder, so stable
export def probe-cache-key [kind: string, script: path]: nothing -> string {
  let c = (ctx)
  let roots = ($env.JIG_STORE_ROOTS | split row " " | each { path basename | str substring 33.. } | sort)
  let id = ({kind: $kind, script: (open --raw $script | hash sha256), triple: $c.platform.triple, roots: $roots, out: $c.out
    flags: [$env.CFLAGS? $env.CXXFLAGS? $env.CPPFLAGS? $env.LDFLAGS? $env.PKG_CONFIG_PATH?]} | to json -r | hash sha256)
  $"probe/($kind)/($id)"
}

export def probe-cache-get [key: string, file: path]: nothing -> bool {
  if not (ctx).cache { return false }
  (do { ^jig cache get $key $file } | complete).exit_code == 0
}

export def probe-cache-put [key: string, file: path]: nothing -> nothing {
  if (ctx).cache and ($file | path exists) { ^jig cache put $key $file | complete | ignore }
}
