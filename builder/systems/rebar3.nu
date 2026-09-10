use ../core.nu *
use ../beam.nu
use ../probe-cache.nu

# rebar3 with the locked Hex packages as _checkouts/, which it takes over the lock without
# asking a registry. Compiled deps round-trip through the cache
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options rebar3)
  load-env {HOME: $c.build, REBAR_CACHE_DIR: $"($c.build)/rebar3-cache", REBAR_OFFLINE: "1", ERL_AFLAGS: "+B", LANG: "C.UTF-8"}
  for tar in (glob $"($o.deps)/packages/hexpm/*.tar") {
    beam unpack $tar $"_checkouts/($tar | path basename | str replace -r '-[^-]+$' "")"
  }
  let key = (probe-cache key $"rebar3-deps/($o.deps | path basename)" [])
  note rebar3-deps (if (probe-cache restore-dir $key _build/default/checkouts) { "restored" } else { "cold" })
}

export def workdir []: nothing -> string { project-dir rebar3 }

export def build []: nothing -> nothing {
  x rebar3 compile ...(options rebar3).flags
  probe-cache store-dir (probe-cache key $"rebar3-deps/((options rebar3).deps | path basename)" []) _build/default/checkouts
}

# opt-in ("rebar3.test" in steps): the test profile's deps are not in rebar.lock
export def test []: nothing -> nothing { x rebar3 eunit }

export def install []: nothing -> nothing {
  x rebar3 escriptize
  for f in (glob _build/default/bin/*) { beam install-escript $f }
}
