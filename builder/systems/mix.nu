use ../core.nu *
use ../beam.nu
use ../probe-cache.nu

# mix at MIX_ENV=prod with deps/ unpacked from fetch.hexDeps, the way `mix deps.get` leaves it:
# deps/<app>/ plus a .hex manifest Hex.SCM.lock_status accepts ("name,version,inner,repo").
# deps.get itself would want registry entries offline. Compiled deps round-trip through the cache
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options mix)
  load-env {
    MIX_ENV: "prod", MIX_HOME: $"($c.build)/mix-home", MIX_ARCHIVES: $"(tool-root hex)/lib/archives"
    MIX_REBAR3: (which rebar3 | get -o path.0 | default ""), MIX_OS_DEPS_COMPILE_PARTITION_COUNT: $"($c.njobs)"
    HEX_HOME: $"($c.build)/hex-home", HEX_OFFLINE: "1", ERL_AFLAGS: "+B", LANG: "C.UTF-8"
  }
  # "app": {:hex, :package, "version", "inner", …}
  let lock = (open --raw mix.lock | parse -r '"(?<app>\w+)": \{:hex, :(?<name>\w+), "(?<version>[^"]+)", "(?<inner>[0-9a-f]{64})"')
  for d in $lock {
    beam unpack $"($o.deps)/packages/hexpm/($d.name)-($d.version).tar" $"deps/($d.app)"
    $"($d.name),($d.version),($d.inner),hexpm" | save $"deps/($d.app)/.hex"
  }
  let key = (probe-cache key $"mix-deps/($o.deps | path basename)" [])
  note mix-deps (if (probe-cache restore-dir $key _build/prod/lib) { "restored" } else { "cold" })
  x mix deps.compile --skip-umbrella-children
  probe-cache store-dir $key _build/prod/lib
}

export def workdir []: nothing -> string { project-dir mix }

export def build []: nothing -> nothing { x mix compile --no-deps-check ...(options mix).flags }

# opt-in ("mix.test" in steps): test-only deps are usually not fetched at MIX_ENV=prod
export def test []: nothing -> nothing { x mix test --no-deps-check }

export def install []: nothing -> nothing {
  let c = (ctx)
  let o = (options mix)
  if ($o.escript | is-empty) {
    x mix release --overwrite --path $"($c.out)/lib/($c.spec.name)"
    mkdir $"($c.out)/bin"
    for f in (ls $"($c.out)/lib/($c.spec.name)/bin" | get name) { ^ln -s $"../lib/($c.spec.name)/bin/($f | path basename)" $"($c.out)/bin/" }
  } else {
    x mix escript.build --no-deps-check
    for e in $o.escript { beam install-escript $e }
  }
}
