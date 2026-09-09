use ../core.nu *

# cabal v2-build against the set's shared hackage repository (locks/hackage.toml), with
# ghc-bootstrap. Dependencies are cached per unit: cabal's unit-id already hashes source, flags,
# compiler and the dependency closure, so a unit built once on this host (by any package) is
# fetched from pkgs-cache instead of compiled. The store directory is the same fixed path in
# every sandbox so the paths inside cached units agree.
def knobs []: nothing -> record<set: string, flags: list<string>, exes: list<string>, project: string> { knobs-for cabal {set: "", flags: [], exes: [], project: ""} }

const STORE = "/build/cabal-store"

# <store>/ghc-<version>-inplace: the units and their package.db
def unit-dir []: nothing -> string { $env.CABAL_UNITS }

# CABAL_DIR with config: no hackage, the set as file+noindex repository, fixed store dir
export def --env setup []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  # cabal writes its index cache into a noindex repository's directory: a writable one of symlinks
  let repo = $"($c.build)/repo"
  mkdir $repo
  for f in (glob $"($k.set)/*.{tar.gz,cabal}") { ^ln -s $f $repo }
  load-env {CABAL_DIR: $"($c.build)/cabal", CABAL_UNITS: $"($STORE)/ghc-(^ghc --numeric-version | str trim)-inplace"}
  mkdir $env.CABAL_DIR $"(unit-dir)/package.db"
  $"repository local
  url: file+noindex://($repo)
store-dir: ($STORE)
jobs: ($c.njobs)
with-compiler: (tool ghc)
" | save -f $"($env.CABAL_DIR)/config"
  cd (project-dir cabal)
  # cc for C bits and linking, one parallel ghc per unit
  $"program-locations\n  gcc-location: (tool cc)\npackage *\n  ghc-options: -j\n  split-sections: True\n($k.project)"
  | save -f cabal.project.local
}

def targets [k: record]: nothing -> list<string> {
  [...($k.flags | each {|f| $"--flags=($f)" }) ...($k.exes | each {|e| $"exe:($e)" })]
}

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
  note cabal-units $"($got | length)/($units | length) from cache"
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
  note cabal-units $"($new | length) stored"
}

# plan, restore cached units, cabal build, store new units
export def build []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  cd (project-dir cabal)
  x cabal build --dry-run ...(targets $k)
  if $c.cache { restore $c }
  let before = (ls -s (unit-dir) | get name)
  x jig slot cabal build ...(targets $k)
  if $c.cache { save-units $c $before }
}

export def test []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  if not $c.testsRun { return }
  cd (project-dir cabal)
  x cabal test --enable-tests ...(targets $k)
}

# the built executables -> $out/bin
export def install []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  cd (project-dir cabal)
  mkdir $"($c.out)/bin"
  for e in $k.exes {
    cp (^cabal list-bin ...(targets $k) $"exe:($e)" | str trim) $"($c.out)/bin/($e)"
  }
}
