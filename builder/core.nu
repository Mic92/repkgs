# The package builder's shared vocabulary. nix/package.nix generates, per package, the script
#   use core.nu *; use prepare.nu; use finish.nu; use <bs>.nu …; prepare; <bs> setup …; <phases> …; finish
# which runs in one nu process, so `def --env` phases hand cwd and environment on to later ones.
# This module is what build systems and inline phases import: ctx, options, x, tool, note, exports.

export use glob.nu *
export use exports.nu *
use names.nu

# One log line per event, in Nix's own structured-log form ("@nix {json}", libutil/logging.cc) so
# `nix build`/nom show the current phase and `nix log` keeps the text. `phase` events become the
# derivation's phase, everything else an info-level message. nix/package.nix emits one per phase
export def note [kind: string, msg: string = ""]: nothing -> nothing {
  let ev = if $kind == "phase" { {action: setPhase, phase: $msg} } else { {action: msg, level: 3, msg: $"($kind): ($msg)"} }
  print -e $"@nix ($ev | to json -r)"
}

# what build-system and inline phases get to see: {spec out deps njobs src build platform testsRun}
export def ctx []: nothing -> record<spec: record, out: string, dest: string, deps: list<record<name: string, root: string>>, roots: list<string>, njobs: int, src: string, build: string, platform: record, testsRun: bool, cache: bool> { $env.PKGS_CTX }

# a build system's options: nix/build-systems.nix defaults merged with the package's `<bs>.*`
export def options [bs: string]: nothing -> record { (ctx).spec | get $bs }

# the directory a build system works in: the source, or `<bs>.root` below it for monorepos
export def project-dir [bs: string]: nothing -> string {
  [(ctx).src (options $bs).root] | path join
}

# store path of the dependency called `name` (its exports name), or an error saying why it is needed
export def dep-root [name: string, why: string]: nothing -> string {
  let d = ((ctx).deps | where name == $name)
  if ($d | is-empty) { error make {msg: $"($why): pkgs.($name) must be in dependencies"} }
  $d.0.root
}

# store path of the build dependency called `name`, for tools that are not a bin/ on PATH
export def tool-root [name: string]: nothing -> string {
  let r = ((attrs).buildDependencies | where { (exports-of $in).name == $name })
  if ($r | is-empty) { error make {msg: $"buildPkgs.($name) must be in buildDependencies"} }
  $r.0
}


# files `names` of `dir` -> $out/bin. finish checks afterwards that every `bin` of the spec exists
export def install-bins [dir: string, names: list<string>]: nothing -> nothing {
  let c = (ctx)
  mkdir $"($c.out)/bin"
  for b in $names { cp $"($dir)/($b)" $"($c.out)/bin/($b)" }
}

# `tests.parallel = false` -> 1, else njobs
export def test-jobs []: nothing -> string { let c = (ctx); if ($c.spec.tests?.parallel? | default true) { $c.njobs } else { 1 } | into string }

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

# file names for this build's platform (names.nu)
export def shlib [name: string, version?: string]: nothing -> string { names shlib (ctx).platform $name $version }
export def linklib [name: string]: nothing -> string { names linklib (ctx).platform $name }
export def shlibdir []: nothing -> string { names shlibdir (ctx).platform }

# the derivation's structured attrs (nix/package.nix `common`)
export def attrs []: nothing -> record { open $env.NIX_ATTRS_JSON_FILE }

# rewrite a text file in place, even one installed read-only: `edit $f { str replace a b }`
export def edit [f: path, change: closure]: nothing -> nothing {
  let text = (open --raw $f | do $change)
  chmod u+w $f
  $text | save -f $f
}

# starts with \x7fELF
export def is-elf [f: path]: nothing -> bool { (open --raw $f | first 4) == 0x[7f 45 4c 46] }

# store paths -> {root}/{store} templates launch expands
export def storerel [p: string, out: string]: nothing -> string {
  $p | str replace -a $out "{root}" | str replace -a $env.NIX_STORE "{store}"
}

# bin/<name> as a launch record (builder/launchers.nu, pkgs/la/launch): `program` with `args`
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
  ^ln -sf $c.platform.launch $"($c.out)/bin/($name)"
  note launcher $"bin/($name) -> ($program)"
}

# no /usr/bin/env in the sandbox: point such scripts at the build PATH's env, and back with --undo
# for installed copies. mtimes are kept, a generator script newer than its shipped output would
# make make regenerate it (coreutils' cu-progs.m4, ruby's prism templates)
export def fix-env-shebangs [dir: path, njobs: int = 4, --undo]: nothing -> nothing {
  let ours = $"#!(tool env)"
  # any line: `ruby -x` stubs carry the real #! after a /bin/sh preamble
  let sub = (if $undo { {from: $"\(?m\)^($ours)", to: "#!/usr/bin/env"} } else { {from: '(?m)^#! ?/usr/bin/env', to: $ours} })
  # installers drop the x bit, so --undo looks at all files
  let grep = (if $undo { $"^($ours)" } else { '^#! ?/usr/bin/env' })
  let hits = (^find $dir -type f ...(if $undo { [] } else { [-perm -u+x] }) -size -1024k -exec grep -lE $grep '{}' + | complete | get stdout | lines)
  if ($hits | is-empty) { return }
  let hits = (^find ...$hits -printf '%T@\t%p\n' | lines | split column "\t" mtime f)
  ^chmod u+w ...$hits.f
  let done = ($hits | par-each --threads ([$njobs 16] | math min) {|h|
    let text = (open --raw $h.f | decode)
    let fixed = ($text | str replace -ar $sub.from $sub.to)
    if $fixed != $text { $fixed | save -f --raw $h.f; $h }
  } | compact)
  if not $undo { for g in ($done | group-by mtime --to-table) { ^touch -d $"@($g.mtime)" ...$g.items.f } }
}
