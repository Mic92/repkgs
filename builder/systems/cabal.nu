use ../core.nu *

# cabal v2-build against the set's shared hackage repository (locks/hackage.toml), with
# ghc-bootstrap. Dependencies are cached per unit: cabal's unit-id already hashes source, flags,
# compiler and the dependency closure, so a unit built once on this host (by any package) is
# fetched from jigd instead of compiled. The store directory is the same fixed path in
# every sandbox so the paths inside cached units agree.
def options []: nothing -> record { options-for cabal {deps: "", flags: [], exes: [], project: ""} }
# under jsem when the daemon is there to hand out slots
def --wrapped cabal [...args: string]: nothing -> any {
  let cmd = (if ($env.JSEM | is-empty) { [cabal ...$args] } else { [jsem cabal ...$args] })
  print -e $"+ ($cmd | str join ' ')"
  run-external ...$cmd
}

const STORE = "/build/cabal-store"

# <store>/ghc-<version>-inplace: the units and their package.db
def unit-dir []: nothing -> string { $env.CABAL_UNITS }

# CABAL_DIR with config: no hackage, the set as file+noindex repository, fixed store dir
export def --env setup []: nothing -> nothing {
  let c = (ctx); let o = (options)
  # cabal writes its index cache into a noindex repository's directory: a writable one of symlinks
  let repo = $"($c.build)/repo"
  mkdir $repo
  for f in (glob $"($o.deps)/*.{tar.gz,cabal}") { ^ln -s $f $repo }
  # with jigd up, ghc's parallelism comes from its slots: `jsem` serves them as the -jsem
  # semaphore. Its name is hashed into unit ids with the other ghc-options, so it is derived from
  # $out: stable across rebuilds, unique on the host
  load-env {CABAL_DIR: $"($c.build)/cabal", CABAL_UNITS: $"($STORE)/ghc-(^ghc --numeric-version | str trim)-inplace"
    JSEM: (if $c.cache { $"/jsem_($c.out | path basename | str substring 0..<32)" } else { "" })}
  mkdir $env.CABAL_DIR $"(unit-dir)/package.db"
  $"repository local
  url: file+noindex://($repo)
store-dir: ($STORE)
jobs: ($c.njobs)
with-compiler: (tool ghc)
" | save -f $"($env.CABAL_DIR)/config"
  cd (project-dir cabal)
  # ghc links through cc without LDFLAGS: dependencies' lib dirs (gmp, libffi, zlib) spelled out
  let libdirs = (dep-dirs $c.deps libDirs | str join ", ")
  $"program-locations\n  gcc-location: (tool cc)\npackage *\n  ghc-options: (if $c.cache { $"-jsem ($env.JSEM)" } else { "-j" })\n  split-sections: True\n  extra-lib-dirs: ($libdirs)\n($o.project)"
  | save -f cabal.project.local
}

# `cabal.flags` ("--flags=…", "--allow-newer", …) go to every cabal subcommand: build, test and list-bin must agree
def targets [o: record]: nothing -> list<string> { $o.flags ++ ($o.exes | each {|e| $"exe:($e)" }) }

# dependency units of the build plan
def plan-units []: nothing -> list<string> {
  open (glob dist-newstyle/cache/plan.json | first) | get install-plan | where type == "configured" and style? == "global" | get id
}

# cached units -> the store, before cabal builds
def restore [c: record]: nothing -> nothing {
  let units = (plan-units)
  let got = ($units | par-each --threads $c.njobs {|id|
    let tar = $"($c.build)/($id).tar.zst"
    if (^jig cache get $"hs:($id)" $tar | complete).exit_code == 0 {
      ^bsdtar -xf $tar -C (unit-dir)
      rm $tar
      $id
    }
  })
  ^ghc-pkg recache $"--package-db=(unit-dir)/package.db"
  note cabal $"($got | length)/($units | length) units cached"
}

# units cabal built this run -> the cache
def save-units [c: record, before: list<string>]: nothing -> nothing {
  let new = (ls -s (unit-dir) | where type == dir and name != "package.db" and name != "incoming" and name not-in $before | get name)
  $new | par-each --threads $c.njobs {|id|
    let tar = $"($c.build)/($id).tar.zst"
    ^bsdtar -c --zstd -f $tar -C (unit-dir) $id $"package.db/($id).conf"
    ^jig cache put $"hs:($id)" $tar | complete | ignore
    rm $tar
  }
  note cabal $"($new | length) units stored"
}

# plan, restore cached units, cabal build, store new units
export def build []: nothing -> nothing {
  let c = (ctx); let o = (options)
  cabal build --dry-run ...(targets $o)
  if $c.cache { restore $c }
  let before = (ls -s (unit-dir) | get name)
  cabal build ...(targets $o)
  if $c.cache { save-units $c $before }
}

export def test []: nothing -> nothing {
  let o = (options)
  # cabal test errors out (Cabal-7043) when the package declares no test-suite, executable-only packages often do not
  let cabals = (glob **/*.cabal --exclude [dist-newstyle/**])
  if ($cabals | is-not-empty) and ($cabals | all {|f| (open --raw $f) !~ '(?im)^\s*test-suite\s' }) { note cabal "no test suites"; return }
  # the package's own test suites (`all:tests` in the project's package, flags still apply)
  cabal test --enable-tests ...$o.flags all:tests
}

# the built executables -> $out/bin
export def install []: nothing -> nothing {
  let c = (ctx); let o = (options)
  mkdir $"($c.out)/bin"
  for e in $o.exes {
    # list-bin takes exactly one target
    cp (cabal list-bin ...$o.flags $"exe:($e)" | str trim) $"($c.out)/bin/($e)"
  }
}
