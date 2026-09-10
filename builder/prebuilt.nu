# What happens to bin/ after install, for our own builds and for upstream binaries.
# launchers (§3): every bin/ script, and every program when a dependency ships bin/ or env, becomes
#   bin/foo -> ../../<hash>-launch/bin/launch, the real file bin/.foo, a record bin/.foo.launch
# (pkgs/la/launch/src/launch.cc). Interpreter from the #! line (resolved among dependencies if it
# was /usr/bin/env or bare), dependencies' bin dirs prepended to PATH, their `env` exports applied
# as defaults.
# implant (`prebuilt = true`): upstream ELFs get our interp, reloc stub and RUNPATH via formatelf.
# `prebuilt = "ldso"` (rust-bootstrap, which formatelf is built with): upstream binaries keep their
# foreign PT_INTERP and run behind a launcher as
#   <sysroot>/lib/ld.so --argv0 <bin/foo> --library-path <libc:deps' libDirs> bin/.foo
# so nothing in the ELF is patched and argv[0] still names bin/foo (rustc finds its sysroot by it).

use core.nu *

# env block shared by all of a package's launchers: dependencies with a bin/ on PATH + every
# dependency's exported env. {} when there is nothing to set
def runtime-env [deps: list<string>, out: string]: nothing -> record {
  let exported = ($deps | each {|d| (exports-of $d).env } | reduce -f {} {|it, acc| $acc | merge $it }
    | items {|k, v| [$k {default: (storerel $v $out)}] } | into record)
  let path = ($deps | where { $"($in)/bin" | path exists } | each {|d| storerel $"($d)/bin" $out })
  (if ($path | is-empty) { {} } else { {PATH: {prepend: $path}} }) | merge $exported
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
  # an absolute store interpreter that is not ours or a (runtime)dependency's is a build tool that
  # got baked in (pip writes the build python into console scripts, xz's configure the build sh
  # into POSIX_SHELL). Left as is, no launcher: for a python library's console script that is the
  # interpreter it was built for, and Nix keeps the reference. Wrong when cross, so said out loud
  if ($interp.0 | str starts-with $store) and not ($owners | any {|d| $interp.0 | str starts-with $"($d)/" }) {
    note script $"bin/($name): #!($interp.0) is a build tool, not a dependency"
    return null
  }
  # bare or /usr/bin/env name: looked up among dependencies (things built for the
  # platform), not on the build PATH: a cross package's script must not point at the builder's python
  let prog = (if ($interp.0 | str starts-with $store) or $interp.0 == "/bin/sh" { $interp.0 } else {
    $owners | each {|d| $"($d)/bin/($interp.0 | path basename)" } | where { path exists } | get 0?
  })
  if $prog == null { return null }
  {program: $prog, args: ($interp | skip 1)}
}

# ELF whose PT_INTERP is not ours (upstream binary in a `prebuilt = "ldso"` package)
def is-foreign [f: path]: nothing -> bool {
  (ctx).spec.prebuilt? == "ldso" and (^llvm-readelf --program-headers $f | str contains INTERP)
}

# what bin/<name> should launch (the launch record minus env), or null to leave the file as is
def target [c: record, f: path, owners: list<string>, inject: bool]: nothing -> oneof<record, nothing> {
  let head = (open --raw $f | into binary | bytes at 0..<256)
  let real = $"{root}/bin/.($f | path basename)"
  if ($head | bytes starts-with 0x[23 21]) {
    let i = (script-interp $f $head $owners $inject)
    if $i != null { {program: (storerel $i.program $c.out), args: ($i.args ++ [$real])} }
  } else if not (is-elf $f) {
    null
  } else if (is-foreign $f) {
    # our libc dir first, then every dependency's lib dirs, relative to the package
    let libdirs = [($c.platform.interp | path dirname)] ++ (dep-dirs $c.deps libDirs)
    let libpath = ($libdirs | each {|p| storerel $p $c.out } | str join ":")
    {program: (storerel $c.platform.interp $c.out), args: [--argv0 "{self}" --library-path $libpath $real]}
  } else if $inject {
    {program: $real, argv0: "{self}"}
  }
}

export def launchers [c: record]: nothing -> nothing {
  let bindir = $"($c.out)/bin"
  if not ($bindir | path exists) { return }
  let a = (attrs)
  let renv = (runtime-env $a.dependencies $c.out)
  let owners = ([$c.out] ++ $a.dependencies)
  let launch_rel = $"../../($c.platform.launch | path relative-to $env.NIX_STORE)"
  # files, and symlinks that resolve inside the package (npm's bin -> lib/node_modules/…/cli.js):
  # the link moves to bin/.<name> beside itself and still resolves
  for f in (ls $bindir | get name | where { ($in | path basename) !~ '^\.' and ($in | path exists) and ($in | path expand) =~ $"^($c.out)/" }) {
    let t = (target $c $f $owners ($renv | is-not-empty))
    if $t == null { continue }
    let name = ($f | path basename)
    # the real file moves to bin/.<name> (same dir, so $ORIGIN RUNPATHs still hold)
    mv $f $"($bindir)/.($name)"
    {env: $renv} | merge $t | to json -r | save -f $"($bindir)/.($name).launch"
    ^ln -s $launch_rel $f
    note launcher $"bin/($name) -> ($t.program)"
  }
}

# `prebuilt = true`: every upstream ELF with a dynamic section gets what our linker would
# have given it, via formatelf: the reloc stub as entry, our ld.so as absolute interp and a RUNPATH
# over libc + dependencies' lib dirs, both with the slack reloc-fixup rewrites in place afterwards
# (pkgs/ji/jig/src/driver.cc kInterpSlack/kRunpathSlack). The file then goes through reloc-fixup
# like one of ours, and keeps a true /proc/self/exe (bun and node re-exec themselves through it).
# `dir`: a tree other than $out, for bindists whose own install step already runs the binaries
# (ghc's `make install` recaches with the installed ghc-pkg). Those get interp + RUNPATH only:
# the stub expects the PT_NULL interp reloc-fixup leaves, and that runs over $out at the end.
export def implant [c: record, dir?: path]: nothing -> nothing {
  let dir = ($dir | default $c.out)
  let elves = (glob $"($dir)/{bin,lib,libexec}/**/*" | where {|f| ($f | path type) == "file" and (is-elf $f) })
  let interp = $"($c.platform.interp | path dirname)/(1..12 | each { './' } | str join)($c.platform.interp | path basename)"
  let libdirs = [($c.platform.interp | path dirname)] ++ (dep-dirs $c.deps libDirs)
  for f in $elves {
    let headers = (^llvm-readelf --program-headers $f)
    # static executables and objects have nothing to resolve
    if not ($headers | str contains "DYNAMIC ") { continue }
    let dirs = ($libdirs ++ (^formatelf --print-rpath $f | str trim | split row ":" | compact -e))
    let runpath = $"($dirs | str join ':'):/('' | fill -c '_' -w (($dirs | length) * 48 - 1))"
    ^chmod u+w $f
    # executables also get our interpreter and the relocation stub. Shared objects only need the
    # RUNPATH: upstream's is $ORIGIN at best, and libc is not there
    let stub = (if $dir == $c.out { [--set-entry-stub $c.platform.relocStub] } else { [] })
    let exe = (if ($headers | str contains "INTERP ") { $stub ++ [--set-interpreter $interp] } else { [] })
    x formatelf ...$exe --set-rpath $runpath $f
    note implant ($f | path relative-to $dir)
  }
}
