# The package builder's shared vocabulary. nix/package.nix generates, per package, the script
#   use core.nu *; use prepare.nu; use finish.nu; use <bs>.nu …; prepare; <bs> setup …; <steps> …; finish
# which runs in one nu process, so `def --env` verbs hand cwd and environment on to later steps.
# This module is what build systems and custom steps import: ctx, options, x, tool, note, exports-of.

# One log line per event, in Nix's own structured-log form ("@nix {json}", libutil/logging.cc) so
# `nix build`/nom show the current phase and `nix log` keeps the text. `step` events become the
# derivation's phase, everything else an info-level message. nix/package.nix emits one per step
export def note [step: string, msg: string = ""]: nothing -> nothing {
  let ev = if $step == "step" { {action: setPhase, phase: $msg} } else { {action: msg, level: 3, msg: $"($step): ($msg)"} }
  print -e $"@nix ($ev | to json -r)"
}

# what build-system verbs and custom steps get to see: {spec out deps njobs src build platform testsRun}
export def ctx []: nothing -> record<spec: record, out: string, deps: list<record<name: string, root: string>>, njobs: int, src: string, build: string, platform: record, testsRun: bool, cache: bool> { $env.PKGS_CTX }

# a build system's options: its defaults overridden by the package's `<bs>.*` attrset
export def options-for [bs: string, defaults: record]: nothing -> record { $defaults | merge ((ctx).spec | get -o $bs | default {}) }

# the directory a build system works in: the source, or `<bs>.root` below it for monorepos
export def project-dir [bs: string]: nothing -> string {
  let root = ((ctx).spec | get -o $bs | get -o root | default ".")
  [(ctx).src $root] | path join
}

# store path of the dependency called `name` (its exports name), or an error saying why it is needed
export def dep-root [name: string, why: string]: nothing -> string {
  let d = ((ctx).deps | where name == $name)
  if ($d | is-empty) { error make {msg: $"($why): pkgs.($name) must be in dependencies"} }
  $d.0.root
}

# absolute directories of one exports field (libDirs, includeDirs, …) across dependencies
export def dep-dirs [deps: list<record<name: string, root: string>>, field: string]: nothing -> list<string> {
  $deps | each {|d| $d | get $field | each {|rel| $"($d.root)/($rel)" } } | flatten
}

# files `names` of `dir` -> $out/bin. finish checks afterwards that every `bin` of the spec exists
export def install-bins [dir: string, names: list<string>]: nothing -> nothing {
  let c = (ctx)
  mkdir $"($c.out)/bin"
  for b in $names { cp $"($dir)/($b)" $"($c.out)/bin/($b)" }
}

# `tests.parallel = false` -> 1, else njobs; and the `tests.skip` patterns
export def test-jobs []: nothing -> string { let c = (ctx); if ($c.spec.tests?.parallel? | default true) { $c.njobs } else { 1 } | into string }
# regexes of test names to leave out
export def test-skips []: nothing -> list<string> { (ctx).spec.tests?.skip? | default [] }

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

# starts with \x7fELF
export def is-elf [f: path]: nothing -> bool { (open --raw $f | into binary | bytes at 0..<4) == 0x[7f 45 4c 46] }

def existing [root: path, rels: list<string>]: nothing -> list<string> { $rels | where {|d| $"($root)/($d)" | path exists } }

# a package's exports with defaults filled in. Used for dependencies and for writing our own
export def exports-of [p: path]: nothing -> record<name: string, includeDirs: list<string>, libDirs: list<string>, libs: list<string>, pkgconfigDirs: list<string>, aclocalDirs: list<string>, env: record, propagate: list<string>> {
  let f = $"($p)/exports.json"
  let e = if ($f | path exists) { open $f } else { {} }
  {
    # package name as build systems key on it (sys-libs.nu, dep-root); the store name is <hash>-<name>[-<platform>]
    name: ($e.name? | default { $p | path basename | str substring 33.. | str replace -r '-(x86_64|aarch64|riscv64|loongarch64|powerpc64le)-\w+$' '' })
    includeDirs: ($e.includeDirs? | default { existing $p ["include"] })
    libDirs: ($e.libDirs? | default { existing $p ["lib"] })
    libs: ($e.libs? | default { glob $"($p)/lib/lib*.so" | each { path parse | get stem | str substring 3.. } | sort })
    pkgconfigDirs: ($e.pkgconfigDirs? | default { existing $p ["lib/pkgconfig" "share/pkgconfig"] })
    aclocalDirs: ($e.aclocalDirs? | default { existing $p ["share/aclocal"] })
    # `{root}` in values: this package's own store path (kept relative in exports.json so the output stays relocatable)
    env: ($e.env? | default {} | items {|k, v| [$k ($v | str replace -a "{root}" $p)] } | into record)
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

# store path -> launcher template relative to the package: {root}/... for our own files,
# {store}/<basename>/... for siblings, anything else verbatim
export def storerel [p: string, out: string]: nothing -> string {
  if ($p | str starts-with $out) {
    $"{root}($p | str substring ($out | str length)..)"
  } else if ($p | str starts-with $"($env.NIX_STORE)/") {
    $"{store}/($p | path relative-to $env.NIX_STORE)"
  } else { $p }
}

# bin/<name> as a launch record (builder/prebuilt.nu, pkgs/la/launch): `program` with `args`
# before the user's, `env` name -> value set for it. For build systems whose entry points are not
# files with a #! line (deno modules); paths are made package-relative here
export def write-launcher [name: string, program: string, args: list<string>, vars: record = {}]: nothing -> nothing {
  let c = (ctx)
  let rel = {|p| storerel $p $c.out }
  mkdir $"($c.out)/bin"
  {
    program: (do $rel $program), args: ($args | each { do $rel $in })
    env: ($vars | items {|k, v| {$k: {set: (do $rel $v)}} } | into record)
  } | to json -r | save -f $"($c.out)/bin/.($name).launch"
  ^ln -sf $"../../($c.platform.launch | path relative-to $env.NIX_STORE)" $"($c.out)/bin/($name)"
  note launcher $"bin/($name) -> ($program)"
}

# no /usr/bin/env in the sandbox: point such scripts at the seed's env (build tree only; installed
# scripts get launchers). mtimes are kept: a generator script newer than its shipped output makes
# make regenerate it (coreutils' cu-progs.m4 -> aclocal, ruby's prism templates -> baseruby)
export def fix-env-shebangs [dir: path, njobs: int = 4]: nothing -> nothing {
  let env_bin = (tool env)
  let magic = ("#!/usr/bin/env" | into binary)
  # find does the walk and the executable/size filter in one process: nu stat-ing 180k llvm files
  # on all cores took 20s, this 1.5s. More than 16 threads only contend on the page cache
  ^find $dir -type f -perm -u+x -size -1024k -printf '%T@ %p\n' | lines
  | par-each --threads ([$njobs 16] | math min) {|l|
    let p = ($l | parse '{mtime} {f}' | first)
    let bytes = (open --raw $p.f | into binary)
    if ($bytes | bytes starts-with $magic) {
      ^chmod u+w $p.f
      ($"#!($env_bin)" | into binary) ++ ($bytes | bytes at ($magic | bytes length)..) | save -f --raw $p.f
      ^touch -d $"@($p.mtime)" $p.f
    }
  } | ignore
}
