use ../core.nu *
use ../beam.nu
use ../build-cache.nu

# rebar3 with the locked Hex packages as _checkouts/, which it takes over the lock without
# asking a registry. Compiled deps round-trip through the cache
export const OPTIONS = {
  flags: {default: [], doc: "extra arguments for rebar3 compile"}
}

export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options rebar3)
  load-env {HOME: $c.build, REBAR_CACHE_DIR: $"($c.build)/rebar3-cache", REBAR_OFFLINE: "1", ERL_AFLAGS: "+B", LANG: "C.UTF-8"
    ERL_COMPILER_OPTIONS: "deterministic"}
  for tar in (files $"($o.deps)/packages/hexpm/*.tar") {
    # <name>-<version>.tar: hex names are [a-z0-9_], versions may have hyphens (2.0.0-rc.2)
    beam unpack $tar $"_checkouts/($tar | path basename | str replace -r '-\d[^/]*$' "")"
  }
  let key = (build-cache key $"rebar3-deps/($o.deps | path basename)" [])
  note rebar3-deps (if (build-cache restore-dir $key _build/default/checkouts) { "restored" } else { "cold" })
}

export def workdir []: nothing -> string { project-dir rebar3 }

export def build []: nothing -> nothing {
  x rebar3 compile ...(options rebar3).flags
  build-cache store-dir (build-cache key $"rebar3-deps/((options rebar3).deps | path basename)" []) _build/default/checkouts
}

# opt-in ("rebar3.test" in phases): the test profile's deps are not in rebar.lock
export def test []: nothing -> nothing { x rebar3 eunit }

export def install []: nothing -> nothing {
  x rebar3 escriptize
  for f in (files _build/default/bin/*) { beam install-escript $f }
}
