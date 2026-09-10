use ../core.nu *
use ../sys-libs.nu

# cargo build/test/install, offline against a vendored registry snapshot. rustc goes through jig's cache.
# features and `cargo.flags`, for build and test alike
def args [o: record<features: list<string>, noDefaultFeatures: bool, flags: list<string>>]: nothing -> list<string> {
  [
    (if $o.noDefaultFeatures { "--no-default-features" })
    (if ($o.features | is-not-empty) { $"--features=($o.features | str join ',')" })
  ] | compact | append $o.flags
}

# CARGO_HOME + config.toml (vendored registry, offline, linker=cc), path remaps
export def --env setup []: nothing -> nothing {
  let c = (ctx); let o = (options cargo)
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
  let rustflags = [$"--remap-path-prefix=($c.src)=/src" $"--remap-path-prefix=($env.CARGO_HOME)=/cargo" $"--remap-path-prefix=($o.deps)=/vendor"]
  {
    source: {crates-io: {replace-with: vendored}, vendored: {directory: $o.deps}}
    net: {offline: true}
    build: {jobs: $c.njobs}
    target: ({$target: {linker: cc, rustflags: $rustflags}}
      | merge (if $c.platform.cross { {$host: {linker: cc-build, rustflags: $rustflags}} } else { {} }))
  } | to toml | save -f $"($env.CARGO_HOME)/config.toml"
  hide-env -i RUSTFLAGS
}

export def workdir []: nothing -> string { project-dir cargo }

# cargo build --release
export def build []: nothing -> nothing { x cargo build --release --offline ...(args (options cargo)) }
# cargo test --release, tests.parallel as --test-threads, tests.skip as --skip filters
export def test []: nothing -> nothing {
  x cargo test --release --offline ...(args (options cargo)) -- --test-threads (test-jobs) ...(test-skips | each { [--skip $in] } | flatten)
}
# the executables cargo built -> $out/bin (those in `bin` when the spec names some), as go does
export def install []: nothing -> nothing {
  let c = (ctx)
  # with CARGO_BUILD_TARGET set cargo always builds into target/<triple>/
  let release = $"($env.CARGO_TARGET_DIR)/($env.CARGO_BUILD_TARGET)/release"
  # cargo's own files there: lib*.rlib/.so/.d and .cargo-lock; the rest are the [[bin]] targets
  let built = (ls -s $release | where type == file and name !~ '^lib|\.(d|rlib)$|^\.' | get name)
  install-bins $release ($built | where { $c.spec.bin? == null or $in in $c.spec.bin })
}
