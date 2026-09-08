use core.nu *
use sys-crates.nu

# cargo build/test/install, offline against a vendored registry snapshot. rustc goes through jig's cache.
def knobs []: nothing -> record<features: list<string>, noDefaultFeatures: bool, root: string, vendor: any> { knobs-for cargo {features: [], noDefaultFeatures: false, root: ".", vendor: null} }

def feature-args [k: record]: nothing -> list<string> {
  [
    (if $k.noDefaultFeatures { "--no-default-features" })
    (if ($k.features | is-not-empty) { $"--features=($k.features | str join ',')" })
  ] | compact
}

# CARGO_HOME + config.toml (vendored registry, offline, linker=cc), rustc cache wrapper, path remaps
export def --env setup []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  $env.CARGO_HOME = $"($c.build)/cargo-home"
  $env.CARGO_TARGET_DIR = $"($c.build)/target"
  mkdir $env.CARGO_HOME
  # RUSTC absolute so the wrapper (and its cache key) sees which rustc, not a bare name
  $env.RUSTC = (tool rustc)
  if $c.cache { $env.RUSTC_WRAPPER = (tool rustcwrap); $env.CARGO_INCREMENTAL = "0" }
  let host = (^rustc -vV | lines | parse "host: {t}" | get t.0)
  # cc targets the platform, cc-build the build machine (rust spells some cpus differently)
  let target = ($c.platform.triple | str replace $c.platform.cpu $c.platform.names.rust)
  $env.CARGO_BUILD_TARGET = $target
  # -sys crates: link our libraries (builder/sys-crates.nu); the vendor dir propagates the ones
  # Cargo.lock asks for. pkg-config, their usual probe, refuses to answer under --target without ALLOW_CROSS
  let sys = (sys-crates env-for $c.deps)
  load-env ({PKG_CONFIG_ALLOW_CROSS: "1"} | merge $sys)
  if ($sys | is-not-empty) { note sys-crates ($sys | columns | str join " ") }
  {
    source: (if $k.vendor != null { {crates-io: {replace-with: vendored}, vendored: {directory: $k.vendor}} } else { {} })
    net: {offline: true}
    build: {jobs: $c.njobs}
    target: ({$target: {linker: cc}} | merge (if $c.platform.cross { {$host: {linker: cc-build}} } else { {} }))
  } | to toml | save -f $"($env.CARGO_HOME)/config.toml"
  # panic strings embed source paths: map build tree, cargo home and vendor dir away.
  # -lld: our cc links with its own lld, rustc >= 1.90 would otherwise insert its bundled rust-lld
  $env.RUSTFLAGS = ([
    -Clinker-features=-lld
    $"--remap-path-prefix=($c.src)=/src"
    $"--remap-path-prefix=($env.CARGO_HOME)=/cargo"
    (if $k.vendor != null { $"--remap-path-prefix=($k.vendor)=/vendor" })
  ] | compact | str join " ")
  cd $"($c.src)/($k.root)"
}

# cargo build --release
export def build []: nothing -> nothing { cd $"((ctx).src)/((knobs).root)"; x cargo build --release --offline ...(feature-args (knobs)) }
# cargo test --release
export def test []: nothing -> nothing {
  if not (ctx).testsRun { return }
  cd $"((ctx).src)/((knobs).root)"
  x cargo test --release --offline ...(feature-args (knobs))
}
# every executable in target/release -> $out/bin
export def install []: nothing -> nothing {
  let c = (ctx)
  mkdir $"($c.out)/bin"
  # with CARGO_BUILD_TARGET set cargo always builds into target/<triple>/
  for b in ($c.spec.bin? | default [$c.spec.name]) { cp $"($env.CARGO_TARGET_DIR)/($env.CARGO_BUILD_TARGET)/release/($b)" $"($c.out)/bin/($b)" }
}
