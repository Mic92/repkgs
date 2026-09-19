# bin/foo becomes a symlink to the `launch` binary (pkgs/la/launch), the real file moves to
# bin/.foo, and bin/.foo.launch is a JSON record saying what to exec and with which environment.
# Used for every script (the record names its interpreter), and for programs too when a
# dependency contributes PATH entries or env defaults.
#
# `prebuilt = "ldso"` packages (rust-bootstrap: formatelf is built with it) also go through
# here: the upstream ELF stays untouched and its launcher runs it as
#   <sysroot>/lib/ld.so --argv0 bin/foo --library-path <libc and deps> bin/.foo
# argv[0] still says bin/foo, which rustc needs to find its sysroot.
#
# PE has no RUNPATH and no dependable symlinks: bin/foo.exe is a *copy* of launch.exe, the record's
# PATH names the store dirs holding its DLLs (also the reference Nix sees).

use core.nu *

# The env part of a package's launch records, the same for all of its bin/ entries:
# PATH gets every dependency that has a bin/, and each dependency's `exports.env` become
# defaults. Empty record when there is nothing to set.
def runtime-env [deps: list<string>, out: string]: nothing -> record {
  let exported = ($deps | each {|d| (exports-of $d).env } | reduce -f {} {|it, acc| $acc | merge $it }
    | items {|k, v| [$k {default: (storerel $v $out)}] } | into record)
  let path = ($deps | where { $"($in)/bin" | path exists } | each {|d| storerel $"($d)/bin" $out })
  (if ($path | is-empty) { {} } else { {PATH: {prepend: $path}} }) | merge $exported
}

# Reads a script's #! line and decides which program should run it.
# Returns {program, args} or null when the script can stay as it is.
def script-interp [f: path, head: binary, owners: list<string>, inject: bool]: nothing -> oneof<record, nothing> {
  let name = ($f | path basename)
  let line = ($head | decode utf-8 | lines | first | str substring 2.. | str trim | split row -r '\s+')
  # /bin/sh exists everywhere (POSIX, NixOS too), so such a script needs no launcher unless
  # there is env to inject
  if $line.0 == "/bin/sh" and not $inject { return null }
  let interp = (if ($line.0 | path basename) == "env" { $line | skip 1 } else { $line })
  let store = $"($env.NIX_STORE)/"
  # A store path that belongs to neither the package nor a dependency is a build tool that
  # leaked in: pip writes the build python into console scripts, xz's configure writes the build
  # sh into POSIX_SHELL. For a cross build that program cannot even run, so the line goes back
  # to `#!/usr/bin/env <name>`: whoever puts the script on PATH brings the interpreter
  if ($interp.0 | str starts-with $store) and not ($owners | any {|d| $interp.0 | str starts-with $"($d)/" }) {
    note script $"bin/($name): #!($interp.0) is a build tool, not a dependency"
    let text = (open --raw $f)
    let body = ($text | str substring ($text | str index-of "\n")..)
    $"#!/usr/bin/env ($interp.0 | path basename)($body)" | save -f $f
    return null
  }
  # A bare name or /usr/bin/env name is looked up in the package and its dependencies, never on
  # the build PATH: a cross-built script must not end up pointing at the build machine's python.
  let prog = (if ($interp.0 | str starts-with $store) or $interp.0 == "/bin/sh" { $interp.0 } else {
    $owners | each {|d| $"($d)/bin/($interp.0 | path basename)" } | where { path exists } | get 0?
  })
  if $prog == null { return null }
  # a #! into our own prefix would dangle
  if ($interp.0 | str starts-with $"((ctx).out)/") {
    let text = (open --raw $f)
    $"#!/usr/bin/env ($interp.0 | path basename)($text | str substring ($text | str index-of "\n")..)" | save -f $f
  }
  {program: $prog, args: ($interp | skip 1)}
}

# An upstream binary in a `prebuilt = "ldso"` package: ELF with a PT_INTERP that is not ours.
def is-foreign [f: path]: nothing -> bool {
  (ctx).spec.prebuilt? == "ldso" and (^llvm-readelf --program-headers $f | str contains INTERP)
}

# The launch record for bin/<name> without the env part, or null to leave the file alone.
#   script          -> its interpreter, with the script as last argument
#   foreign ELF     -> our ld.so with --library-path over libc and the dependencies
#   our own ELF     -> itself, only when there is env to inject. argv[0] stays what the user ran,
#                      so a symlink to bin/python3 from a venv still finds its pyvenv.cfg
def target [c: record, f: path, owners: list<string>, inject: bool]: nothing -> oneof<record, nothing> {
  let head = (open --raw $f | into binary | bytes at 0..<256)
  let real = $"{root}/bin/.($f | path basename)"
  if ($head | bytes starts-with 0x[23 21]) {
    let i = (script-interp $f $head $owners $inject)
    # a symlinked script runs by its real path so its $0 logic holds
    let script = (if ($f | path type) == symlink { storerel ($f | path expand) $c.out } else { $real })
    if $i != null { {program: (storerel $i.program $c.out), args: ($i.args ++ [$script])} }
  } else if not (is-elf $f) {
    null
  } else if (is-foreign $f) {
    let libdirs = [($c.platform.interp | path dirname)] ++ (dep-dirs $c.deps libDirs)
    let libpath = ($libdirs | each {|p| storerel $p $c.out } | str join ":")
    {program: (storerel $c.platform.interp $c.out), args: [--argv0 "{self}" --library-path $libpath $real]}
  } else if $inject {
    {program: $real, argv0: "{argv0}"}
  }
}

# a DLL the OS provides: the toolchain has an import library for it
def system-dll [sysroot: string, n: string]: nothing -> bool {
  let stem = ($n | str replace -r '\.dll$' "")
  $n =~ '^(api-ms-win-|ext-ms-)' or ($"($sysroot)/lib/lib($stem).a" | path exists) or (glob $"($sysroot)/sdk/lib/*/um/*/($stem).lib" | is-not-empty)
}

# lowercased, delay-loaded ones (probed at run time, optional) left out
def imports [f: path]: nothing -> list<string> {
  ^llvm-readobj --coff-imports $f | parse -r '(?m)^\s*Import \{\s*Name: (?<n>\S+)' | get n | str lowercase
}

# One PATH for the package: every dir, own or a dependency's, holding a DLL that any of our PEs
# imports, plus what those dependencies recorded for *their* DLLs (dllDirs, transitively filled).
# An import found nowhere and not in the OS is an undeclared dependency: an error now, not at run time
def pe [c: record, deps: list<string>, renv: record]: nothing -> nothing {
  let pes = (files $"($c.out)/**/*.{exe,dll,pyd}")
  let exports = ($deps | each { exports-of $in })
  # the toolchain's runtime DLLs (libc++, libunwind) count like a dependency's, by their real dir
  let dirs = (($pes | path dirname) ++ ($deps | each {|d| [$"($d)/bin" $"($d)/lib"] } | flatten) ++ [$"($c.platform.sysroot)/bin"] | uniq | where { path exists })
  let has = ($dirs | each {|d| {d: $d, dlls: (ls -l $d | update name { path basename | str lowercase })} })
  let need = ($pes | each { imports $in } | flatten | uniq | each {|n|
    let hit = ($has | each {|h| $h.dlls | where name == $n | each {|e| $h.d | path join ($e.target? | default $n) | path expand | path dirname } } | flatten | get -o 0)
    if $hit == null and not (system-dll $c.platform.sysroot $n) {
      error make {msg: $"($n) is imported but neither the package, a dependency nor the OS provides it"}
    }
    $hit
  } | compact) ++ ($exports.dllDirs | flatten) | uniq
  let foreign = ($need | where { not ($in | str starts-with $c.out) })
  for f in ($pes | where { $in ends-with .exe }) {
    let path = ($need | where { $in != ($f | path dirname) } | each { storerel $in $c.out }) ++ ($renv.PATH?.prepend? | default [])
    if ($path | is-empty) and ($renv | is-empty) { continue }
    let rel = ($f | path relative-to $c.out)
    mv $f $"($f | path dirname)/.($f | path basename)"
    {env: ($renv | upsert PATH {prepend: $path}), program: $"{root}/($rel | path dirname)/.($rel | path basename)"} | to json -r | save -f $"($f | path dirname)/.($f | path basename).launch"
    cp $c.platform.launch $f
    note launcher $"($rel): PATH += ($foreign | each { path dirname | path basename } | str join ' ')"
  }
  if ($foreign | is-not-empty) {
    let f = $"($c.out)/exports.json"
    (if ($f | path exists) { open $f } else { {} }) | upsert dllDirs $foreign | to json | save -f $f
  }
}

export def main [c: record]: nothing -> nothing {
  let a = (attrs)
  if $c.platform.binfmt == "coff" { return (pe $c $a.dependencies (runtime-env $a.dependencies $c.out)) }
  let bindir = $"($c.out)/bin"
  if not ($bindir | path exists) { return }
  let renv = (runtime-env $a.dependencies $c.out)
  let owners = ([$c.out] ++ $a.dependencies)
  # not what write-launcher already made, not sibling aliases (python3 -> python3.14)
  let entries = (ls -a $bindir | get name | where {|f| ($f | path basename) !~ '^\.' and ($f | path exists) and not ($"($bindir)/.($f | path basename).launch" | path exists) })
  let sibling = {|f| ($f | path type) == symlink and ($bindir | path join (^readlink $f) | path expand -n | path dirname) == $bindir }
  for f in ($entries | where {|f| not (do $sibling $f) }) {
    let t = (target $c $f $owners ($renv | is-not-empty))
    if $t == null { continue }
    let name = ($f | path basename)
    # bin/.<name> is in the same directory, so $ORIGIN-relative RUNPATHs keep working
    mv $f $"($bindir)/.($name)"
    {env: $renv} | merge $t | to json -r | save -f $"($bindir)/.($name).launch"
    ^ln -s $c.platform.launch $f # absolute until to-store, later entries may name this one
    note launcher $"bin/($name) -> ($t.program)"
  }
}
