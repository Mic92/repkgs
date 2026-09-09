# §3: every bin/ script and every program with runtimeDependencies becomes
#   bin/foo -> ../../<hash>-launch/bin/launch, the real file bin/.foo, a record bin/.foo.launch
# (pkgs/la/launch/src/launch.cc).
# Interpreter from the #! line (resolved among dependencies if it was /usr/bin/env or bare),
# runtimeDependencies' bin dirs prepended to PATH, their `env` exports applied as defaults.
# `prebuilt = "ldso"` (rust, which formatelf is built with): upstream binaries keep their foreign
# PT_INTERP and run as
#   <sysroot>/lib/ld.so --argv0 <bin/foo> --library-path <libc:deps' libDirs> bin/.foo
# so nothing in the ELF is patched and argv[0] still names bin/foo (rustc finds its sysroot by it).
# /proc/self/exe is ld.so then. Every other prebuilt package gets the implant (builder/finish.nu).
use core.nu *

# env block shared by all of a package's launchers: runtimeDependencies on PATH + their exported env
def runtime-env [rdeps: list<string>, out: string]: nothing -> record {
  if ($rdeps | is-empty) { return {} }
  let exported = ($rdeps | each {|d| (exports-of $d).env } | reduce -f {} {|it, acc| $acc | merge $it }
    | items {|k, v| [$k {default: (storerel $v $out)}] } | into record)
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

# ELF whose PT_INTERP is not ours (upstream binary in a `prebuilt = "ldso"` package)
def is-foreign [f: path]: nothing -> bool {
  (ctx).spec.prebuilt? == "ldso" and (^llvm-readelf --program-headers $f | str contains INTERP)
}

# what bin/<name> should launch (the launch record minus env), or null to leave the file as is
def target [c: record<spec: record, out: string, deps: list<record>, njobs: int, src: string, build: string, platform: record, testsRun: bool, cache: bool>, f: path, owners: list<string>, rdeps: list<string>]: nothing -> oneof<record, nothing> {
  let head = (open --raw $f | into binary | bytes at 0..<256)
  let real = $"{root}/bin/.($f | path basename)"
  if ($head | bytes starts-with 0x[23 21]) {
    let i = (script-interp $f $head $owners ($rdeps | is-not-empty))
    if $i != null { {program: (storerel $i.program $c.out), args: ($i.args ++ [$real])} }
  } else if not (is-elf $f) {
    null
  } else if (is-foreign $f) {
    # our libc dir first, then every dependency's lib dirs, relative to the package
    let libdirs = [($c.platform.interp | path dirname)] ++ (dep-dirs $c.deps libDirs)
    let libpath = ($libdirs | each {|p| storerel $p $c.out } | str join ":")
    {program: (storerel $c.platform.interp $c.out), args: [--argv0 "{self}" --library-path $libpath $real]}
  } else if ($rdeps | is-not-empty) {
    {program: $real, argv0: "{self}"}
  }
}

export def main [c: record<spec: record, out: string, deps: list<record>, njobs: int, src: string, build: string, platform: record, testsRun: bool, cache: bool>]: nothing -> nothing {
  let bindir = $"($c.out)/bin"
  if not ($bindir | path exists) { return }
  let a = (attrs)
  let rdeps = ($a.runtimeDependencies? | default [])
  let renv = (runtime-env $rdeps $c.out)
  let owners = ([$c.out] ++ $a.dependencies ++ $rdeps)
  let launch_rel = $"../../($c.platform.launch | path relative-to $env.NIX_STORE)"
  # files, and symlinks that resolve inside the package (npm's bin -> lib/node_modules/…/cli.js):
  # the link moves to bin/.<name> beside itself and still resolves
  for f in (ls $bindir | get name | where { ($in | path basename) !~ '^\.' and ($in | path exists) and ($in | path expand) =~ $"^($c.out)/" }) {
    let t = (target $c $f $owners $rdeps)
    if $t == null { continue }
    let name = ($f | path basename)
    # the real file moves to bin/.<name> (same dir, so $ORIGIN RUNPATHs still hold)
    mv $f $"($bindir)/.($name)"
    {env: $renv} | merge $t | to json -r | save -f $"($bindir)/.($name).launch"
    ^ln -s $launch_rel $f
    note launcher $"bin/($name) -> ($t.program)"
  }
}
