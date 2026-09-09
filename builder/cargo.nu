use core.nu *
use sys-libs.nu

# cargo build/test/install, offline against a vendored registry snapshot. rustc goes through jig's cache.
def knobs []: nothing -> record<features: list<string>, noDefaultFeatures: bool, vendor: any> { knobs-for cargo {features: [], noDefaultFeatures: false, vendor: null} }

def feature-args [k: record<features: list<string>, noDefaultFeatures: bool>]: nothing -> list<string> {
  [
    (if $k.noDefaultFeatures { "--no-default-features" })
    (if ($k.features | is-not-empty) { $"--features=($k.features | str join ',')" })
  ] | compact
}

# CARGO_HOME + config.toml (vendored registry, offline, linker=cc), path remaps
export def --env setup []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  load-env {CARGO_HOME: $"($c.build)/cargo-home", CARGO_TARGET_DIR: $"($c.build)/target", RUSTC: (tool rustc)}
  mkdir $env.CARGO_HOME
  let host = (^rustc -vV | lines | parse "host: {t}" | get t.0)
  # cc targets the platform, cc-build the build machine (rust spells some cpus differently)
  let target = ($c.platform.triple | str replace $c.platform.cpu $c.platform.names.rust)
  $env.CARGO_BUILD_TARGET = $target
  # -sys crates: link our libraries (builder/sys-libs.nu); the vendor dir propagates the ones
  # Cargo.lock asks for. pkg-config, their usual probe, refuses to answer under --target without ALLOW_CROSS
  let sys = (sys-libs env-for cargo $c.deps)
  load-env ({PKG_CONFIG_ALLOW_CROSS: "1"} | merge $sys)
  if ($sys | is-not-empty) { note sys-libs ($sys | columns | str join " ") }
  # rustflags per target in config (RUSTFLAGS from the environment would replace them): panic
  # strings embed source paths, map build tree, cargo home and vendor dir away
  let rustflags = ([
    $"--remap-path-prefix=($c.src)=/src"
    $"--remap-path-prefix=($env.CARGO_HOME)=/cargo"
    (if $k.vendor != null { $"--remap-path-prefix=($k.vendor)=/vendor" })
  ] | compact)
  {
    source: (if $k.vendor != null { {crates-io: {replace-with: vendored}, vendored: {directory: $k.vendor}} } else { {} })
    net: {offline: true}
    build: {jobs: $c.njobs}
    target: ({$target: {linker: cc, rustflags: $rustflags}}
      | merge (if $c.platform.cross { {$host: {linker: cc-build, rustflags: $rustflags}} } else { {} }))
  } | to toml | save -f $"($env.CARGO_HOME)/config.toml"
  hide-env -i RUSTFLAGS
  cd (project-dir cargo)
}

# cargo build --release
export def build []: nothing -> nothing { cd (project-dir cargo); x cargo build --release --offline ...(feature-args (knobs)) }
# cargo test --release
export def test []: nothing -> nothing {
  if not (ctx).testsRun { return }
  cd (project-dir cargo)
  x cargo test --release --offline ...(feature-args (knobs))
}
# the spec's `bin` entries cargo built -> $out/bin. Others (symlinks a later step adds) are left
# to that step; finish checks that every `bin` exists in the end
export def install []: nothing -> nothing {
  let c = (ctx)
  mkdir $"($c.out)/bin"
  # with CARGO_BUILD_TARGET set cargo always builds into target/<triple>/
  let release = $"($env.CARGO_TARGET_DIR)/($env.CARGO_BUILD_TARGET)/release"
  let built = ($c.spec.bin? | default [$c.spec.name] | where {|b| $"($release)/($b)" | path exists })
  if ($built | is-empty) { error make {msg: $"cargo.install: none of ($c.spec.bin? | default [$c.spec.name]) in ($release)"} }
  for b in $built { cp $"($release)/($b)" $"($c.out)/bin/($b)" }
}
