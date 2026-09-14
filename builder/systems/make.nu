use ../core.nu *

# plain Makefile projects: make [targets] flags, in the source tree, after the project's
# hand-written `make.configureScript` when it has one. autotools.nu builds on this

export def --env setup []: nothing -> nothing {
  let sh = (if (which bash | is-not-empty) { tool bash } else { tool sh })
  load-env {CONFIG_SHELL: $sh, SHELL: $sh}
}

export def workdir []: nothing -> string { project-dir make }

# #!/bin/sh would be the sandbox's. MAKEFLAGS for scripts that compile (cmake's bootstrap)
export def configure []: nothing -> nothing {
  let c = (ctx); let o = (options make)
  let script = $"./($o.configureScript)"
  if not ($script | path exists) { return }
  let argv = (if (open --raw $script | lines | first) =~ '^#! ?/bin/sh' { [$env.CONFIG_SHELL $script] } else { [$script] })
  with-env {MAKEFLAGS: $"-j($c.njobs)"} { x ($argv | first) ...($argv | skip 1) $"--prefix=($c.out)" ...$o.configureFlags }
}

export def run-build [flags: list<string>, targets: list<string>]: nothing -> nothing { x make $"-j((ctx).njobs)" ...$targets ...$flags }

export def run-test [flags: list<string>, targets: list<string>]: nothing -> nothing { x make $"-j(test-jobs)" ...$targets ...$flags }

# PREFIX/prefix for hand-written Makefiles, configure'd ones ignore them
export def run-install [flags: list<string>, targets: list<string>]: nothing -> nothing {
  let out = (ctx).out
  x make ...$targets $"PREFIX=($out)" $"prefix=($out)" ...$flags
}

export def build []: nothing -> nothing { let o = (options make); run-build $o.flags $o.buildTarget }
export def test []: nothing -> nothing { let o = (options make); run-test $o.flags $o.testTarget }
export def install []: nothing -> nothing { let o = (options make); run-install ($o.flags ++ $o.installFlags) $o.installTarget }
