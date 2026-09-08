# §3: every bin/ script and every program with runtimeDependencies becomes
#   bin/foo -> ../../<hash>-launch/bin/launch   plus a record bin/.foo.launch (pkgs/la/launch/src/launch.cc).
# Interpreter from the #! line (resolved among dependencies if it was /usr/bin/env or bare),
# runtimeDependencies' bin dirs prepended to PATH, their `env` exports applied as defaults.
# `prebuilt = true`: upstream binaries keep their foreign PT_INTERP and run as
#   <sysroot>/lib/ld.so --argv0 <bin/foo> --library-path <libc:deps' libDirs> libexec/foo
# so nothing in the ELF is patched and argv[0] still names bin/foo (rustc finds its sysroot by it).
use core.nu *

# env block shared by all of a package's launchers: runtimeDependencies on PATH + their exported env
def runtime-env [rdeps: list<string>, out: string]: nothing -> record {
  if ($rdeps | is-empty) { return {} }
  let exported = ($rdeps | each {|d| (exports-of $d).env | items {|k, v| {k: $k, v: {default: (storerel $v $out)}} } }
    | flatten | reduce -f {} {|it, acc| $acc | insert $it.k $it.v })
  {PATH: {prepend: ($rdeps | each {|d| storerel $"($d)/bin" $out })}} | merge $exported
}

# the program a script's #! names, as an absolute path that is ours or a dependency's. null = leave
# the script alone (plain #!/bin/sh with nothing to inject)
def script-interp [f: path, head: binary, owners: list<string>, inject: bool]: nothing -> oneof<record, nothing> {
  let name = ($f | path basename)
  let line = ($head | decode utf-8 | lines | first | str substring 2.. | str trim | split row -r '\s+')
  # `#!/bin/sh` is the one ambient interpreter (POSIX guarantees it, NixOS has it)
  if $line.0 == "/bin/sh" and not $inject { return null }
  let interp = (if ($line.0 | path basename) == "env" { $line | skip 1 } else { $line })
  let store = $"($env.NIX_STORE)/"
  # an absolute store interpreter must belong to us or a (runtime)dependency: configure likes to
  # bake in build tools (xz: POSIX_SHELL = the build machine's sh, wrong arch when cross)
  if ($interp.0 | str starts-with $store) and not ($owners | any {|d| $interp.0 | str starts-with $"($d)/" }) {
    error make {msg: $"bin/($name): #!($interp.0) is a build tool, not a dependency"}
  }
  # bare or /usr/bin/env name: looked up in dependencies + runtimeDependencies (things built for the
  # platform), not on the build PATH: a cross package's script must not point at the builder's python
  let prog = (if ($interp.0 | str starts-with $store) or $interp.0 == "/bin/sh" { $interp.0 } else {
    $owners | each {|d| $"($d)/bin/($interp.0 | path basename)" } | where { path exists } | get 0? | default null
  })
  if $prog == null { error make {msg: $"bin/($name): interpreter ($interp.0) is not a dependency"} }
  {program: $prog, args: ($interp | skip 1)}
}

export def main [c: record]: nothing -> nothing {
  let bindir = $"($c.out)/bin"
  if not ($bindir | path exists) { return }
  let a = (attrs)
  let rdeps = ($a.runtimeDependencies? | default [])
  let renv = (runtime-env $rdeps $c.out)
  let owners = ([$c.out] ++ $a.dependencies ++ $rdeps)
  let prebuilt = ($c.spec.prebuilt? | default false)
  # our libc + runtimes first, then every dependency's lib dirs, relative to the package
  let libpath = (if $prebuilt {
    [($c.platform.interp | path dirname)] ++ ($c.deps | each {|d| $d.libDirs | each {|l| $"($d.root)/($l)" } } | flatten)
    | each {|p| storerel $p $c.out } | str join ":"
  })
  let launch_rel = $"../../($c.platform.launch | path relative-to $env.NIX_STORE)"
  for f in (ls $bindir | where type == file | get name) {
    let name = ($f | path basename)
    let head = (open --raw $f | into binary | bytes at 0..<256)
    let is_script = ($head | bytes starts-with 0x[23 21])
    let rec = (if $is_script {
      let i = (script-interp $f $head $owners ($rdeps | is-not-empty))
      if $i == null { continue }
      mv $f $"($bindir)/.($name).script"
      {env: $renv, program: (storerel $i.program $c.out), args: ($i.args ++ [$"{root}/bin/.($name).script"])}
    } else if $prebuilt and (is-elf $f) {
      mkdir $"($c.out)/libexec"
      mv $f $"($c.out)/libexec/($name)"
      {env: $renv, program: (storerel $c.platform.interp $c.out), args: [--argv0 "{self}" --library-path $libpath $"{root}/libexec/($name)"]}
    } else if (is-elf $f) and ($rdeps | is-not-empty) {
      mkdir $"($c.out)/libexec"
      mv $f $"($c.out)/libexec/($name)"
      {env: $renv, program: $"{root}/libexec/($name)", argv0: "{self}"}
    } else { continue })
    $rec | to json -r | save -f $"($bindir)/.($name).launch"
    ^ln -s $launch_rel $f
    note launcher $"bin/($name) -> ($rec.program)"
  }
}
