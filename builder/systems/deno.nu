use ../core.nu *

# A deno application: type-checked and tested against its fetch.denoDeps DENO_DIR (`deno.deps`),
# installed as lib/<name>/ (project tree + that DENO_DIR) with a bin/<bin> launcher per
# `deno.entry` (bin name -> module path) running `deno run --cached-only` on it. pkgs.deno must be
# a dependency. No `deno compile` yet: it splices into upstream's denort ELF, which would need
# relinking first.
# DENO_DIR: a writable copy of deno.deps (deno adds gen/ and *_cache_v2 next to npm/ and remote/)
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options deno)
  let deno_dir = $"($c.build)/deno-dir"
  ^cp -r $o.deps $deno_dir
  ^chmod -R u+w $deno_dir
  load-env {DENO_DIR: $deno_dir, DENO_NO_UPDATE_CHECK: "1", NO_COLOR: "1"}
}

export def workdir []: nothing -> string { project-dir deno }

# type-check the entry points unless deno.check = false
export def build []: nothing -> nothing {
  let o = (options deno)
  if $o.check and ($o.entry | is-not-empty) { x deno check --cached-only --frozen ...($o.entry | values) }
}

# deno test
export def test []: nothing -> nothing {
  let o = (options deno)
  x deno test --cached-only --frozen ...$o.permissions ...$o.flags
}

# lib/<name>/ = project + its DENO_DIR; bin/<bin> = launch record running deno on the entry module
export def install []: nothing -> nothing {
  let c = (ctx)
  let o = (options deno)
  let deno = (dep-root deno "deno applications run on it")
  let app = $"($c.out)/lib/($c.spec.name)"
  mkdir ($app | path dirname)
  ^cp -r (project-dir deno) $app
  ^cp -r $o.deps $"($app)/deno-dir"
  let config = ([deno.json deno.jsonc] | each { $"($app)/($in)" } | where { path exists } | each { $"--config=($in)" })
  for bin in ($o.entry | transpose name module) {
    let args = [run --cached-only --frozen ...$config ...$o.permissions ...$o.flags $"($app)/($bin.module)"]
    write-launcher $bin.name $"($deno)/bin/deno" $args {DENO_DIR: $"($app)/deno-dir", DENO_NO_UPDATE_CHECK: "1"}
  }
}
