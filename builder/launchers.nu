# bin/foo becomes a symlink to the `launch` binary (pkgs/la/launch), the real file moves to
# bin/.foo, and bin/.foo.launch is a JSON record saying what to exec and with which environment.
# Used for every script (the record names its interpreter), and for programs too when a
# dependency contributes PATH entries or env defaults.
#
# `prebuilt = "ldso"` packages (rust-bootstrap, which formatelf itself is built with) also go
# through here: the upstream ELF stays untouched and its launcher runs it as
#   <sysroot>/lib/ld.so --argv0 bin/foo --library-path <libc and deps> bin/.foo
# argv[0] still says bin/foo, which rustc needs to find its sysroot.

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
    if $i != null { {program: (storerel $i.program $c.out), args: ($i.args ++ [$real])} }
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

export def main [c: record]: nothing -> nothing {
  let bindir = $"($c.out)/bin"
  if not ($bindir | path exists) { return }
  let a = (attrs)
  let renv = (runtime-env $a.dependencies $c.out)
  let owners = ([$c.out] ++ $a.dependencies)
  let launch_rel = $"../../($c.platform.launch | path relative-to $env.NIX_STORE)"
  # Candidates: regular files, and symlinks that resolve inside the package (npm links bin/x to
  # lib/node_modules/…/cli.js). Not: a symlink to a sibling like python3 -> python3.14. The
  # sibling gets the launcher, the alias keeps pointing at it, and argv[0] keeps the alias
  # name. Wrapping the alias too would make it launch the sibling's launcher, which launches
  # it again, forever.
  let entries = (ls -a $bindir | get name | where { ($in | path basename) !~ '^\.' and ($in | path exists) and ($in | path expand) =~ $"^($c.out)/" })
  for f in ($entries | where {|f| ($f | path type) != symlink or (^readlink $f) =~ '/' }) {
    let t = (target $c $f $owners ($renv | is-not-empty))
    if $t == null { continue }
    let name = ($f | path basename)
    # bin/.<name> is in the same directory, so $ORIGIN-relative RUNPATHs keep working
    mv $f $"($bindir)/.($name)"
    {env: $renv} | merge $t | to json -r | save -f $"($bindir)/.($name).launch"
    ^ln -s $launch_rel $f
    note launcher $"bin/($name) -> ($t.program)"
  }
}
