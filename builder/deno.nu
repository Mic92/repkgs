use core.nu *

# A deno application: type-checked and tested against its fetch.denoDeps DENO_DIR (`deno.deps`),
# installed as lib/<name>/ (project tree + that DENO_DIR) with a bin/<bin> launcher per
# `deno.entry` (bin name -> module path) running `deno run --cached-only` on it. pkgs.deno must be
# a dependency. No `deno compile` yet: it splices into upstream's denort ELF, which would need
# relinking first.
def knobs []: nothing -> record<deps: any, entry: record, permissions: list<string>, test: bool, check: bool, flags: list<string>> {
  knobs-for deno {deps: null, entry: {}, permissions: ["-A"], test: true, check: true, flags: []}
}

# DENO_DIR: a writable copy of deno.deps (deno adds gen/ and *_cache_v2 next to npm/ and remote/)
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  if $k.deps == null { error make {msg: "deno: set deno.deps = fetch.denoDeps { source = …; }"} }
  let deno_dir = $"($c.build)/deno-dir"
  ^cp -r $k.deps $deno_dir
  ^chmod -R u+w $deno_dir
  load-env {DENO_DIR: $deno_dir, DENO_NO_UPDATE_CHECK: "1", NO_COLOR: "1"}
  cd (project-dir deno)
}

# type-check the entry points unless deno.check = false
export def build []: nothing -> nothing {
  let k = (knobs)
  if $k.check and ($k.entry | is-not-empty) { cd (project-dir deno); x deno check --cached-only --frozen ...($k.entry | values) }
}

# `deno test` unless deno.test = false
export def test []: nothing -> nothing {
  let k = (knobs)
  if $k.test { cd (project-dir deno); x deno test --cached-only --frozen ...$k.permissions ...$k.flags }
}

# lib/<name>/ = project + its DENO_DIR; bin/<bin> = launch record running deno on the entry module
export def install []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  let deno = (dep-root deno "deno applications run on it")
  let app = $"($c.out)/lib/($c.spec.name)"
  mkdir ($app | path dirname)
  ^cp -r (project-dir deno) $app
  ^cp -r $k.deps $"($app)/deno-dir"
  let config = ([deno.json deno.jsonc] | each { $"($app)/($in)" } | where { path exists } | each { $"--config=($in)" })
  for bin in ($k.entry | transpose name module) {
    let args = [run --cached-only --frozen ...$config ...$k.permissions ...$k.flags $"($app)/($bin.module)"]
    write-launcher $bin.name $"($deno)/bin/deno" $args {DENO_DIR: $"($app)/deno-dir", DENO_NO_UPDATE_CHECK: "1"}
  }
}
