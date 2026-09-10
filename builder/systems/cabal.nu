use ../core.nu *

# cabal v2-build against the set's shared hackage repository (locks/hackage.toml), with
# ghc-bootstrap. Dependencies are cached per unit: cabal's unit-id already hashes source, flags,
# compiler and the dependency closure, so a unit built once on this host (by any package) is
# fetched from jigd instead of compiled. The store directory is the same fixed path in
# every sandbox so the paths inside cached units agree.
def --wrapped cabal [...args: string]: nothing -> any {
  print -e $"+ cabal ($args | str join ' ')"
  ^cabal ...$args
}

const STORE = "/build/cabal-store"

# cabal's storeDirectory: <store>/<ghc --info "Project Unit Id">
def unit-dir []: nothing -> string { $env.CABAL_UNITS }

# CABAL_DIR with config: no hackage, the set as file+noindex repository, fixed store dir
export def --env setup []: nothing -> nothing {
  let c = (ctx); let o = (options cabal)
  # cabal writes its index cache into a noindex repository's directory: a writable one of symlinks
  let repo = $"($c.build)/repo"
  mkdir $repo
  for f in (glob $"($o.deps)/*.{tar.gz,cabal}") { ^ln -s $f $repo }
  let unit_id = (^ghc --info | parse --regex '"Project Unit Id","([^"]+)"' | get capture0.0)
  load-env {CABAL_DIR: $"($c.build)/cabal", CABAL_UNITS: $"($STORE)/($unit_id)"}
  mkdir $env.CABAL_DIR $"(unit-dir)/package.db"
  # `semaphore`: cabal passes -jsem to ghc itself, outside the ghc-options that unit ids hash.
  # ghc runs under jsem (pkgs/js/jsem), which feeds that semaphore from jigd's slots
  let ghc = $"($c.build)/ghc"
  $"#!(tool sh)\nexec (tool jsem) (tool ghc) \"$@\"\n" | save -f $ghc
  chmod +x $ghc
  $"repository local
  url: file+noindex://($repo)
store-dir: ($STORE)
jobs: ($c.njobs)
semaphore: True
with-compiler: ($ghc)
with-hc-pkg: (tool ghc-pkg)
" | save -f $"($env.CABAL_DIR)/config"
  $"program-locations\n  gcc-location: (tool cc)\npackage *\n  split-sections: True\n($o.project)"
  | save -f cabal.project.local
}

export def workdir []: nothing -> string { project-dir cabal }

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

# units cabal built this run -> the cache. Executable units (alex, happy: build tools of other
# packages) have no package.db entry, just bin/
def save-units [c: record, before: list<string>]: nothing -> nothing {
  let new = (ls -s (unit-dir) | where type == dir and name != "package.db" and name != "incoming" and name not-in $before | get name)
  $new | par-each --threads $c.njobs {|id|
    let tar = $"($c.build)/($id).tar.zst"
    let conf = ([$"package.db/($id).conf"] | where { $"(unit-dir)/($in)" | path exists })
    ^bsdtar -c --zstd -f $tar -C (unit-dir) $id ...$conf
    ^jig cache put $"hs:($id)" $tar | complete | ignore
    rm $tar
  }
  note cabal $"($new | length) units stored"
}

# plan, restore cached units, cabal build, store new units
export def build []: nothing -> nothing {
  let c = (ctx); let o = (options cabal)
  cabal build --dry-run ...(targets $o)
  if $c.cache { restore $c }
  let before = (ls -s (unit-dir) | get name)
  cabal build ...(targets $o)
  if $c.cache { save-units $c $before }
}

export def test []: nothing -> nothing {
  let o = (options cabal)
  # cabal test errors out (Cabal-7043) when the package declares no test-suite, executable-only packages often do not
  let cabals = (glob **/*.cabal --exclude [dist-newstyle/**])
  if ($cabals | is-not-empty) and ($cabals | all {|f| (open --raw $f) !~ '(?im)^\s*test-suite\s' }) { note cabal "no test suites"; return }
  # the package's own test suites (`all:tests` in the project's package, flags still apply)
  cabal test --enable-tests ...$o.flags all:tests
}

# the built executables -> $out/bin
export def install []: nothing -> nothing {
  let c = (ctx); let o = (options cabal)
  mkdir $"($c.out)/bin"
  for e in $o.exes {
    # list-bin takes exactly one target
    cp (cabal list-bin ...$o.flags $"exe:($e)" | str trim) $"($c.out)/bin/($e)"
  }
}
