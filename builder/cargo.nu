use core.nu *

# cargo build/test/install, offline against a vendored registry snapshot. rustc goes through jig's cache.
def knobs []: nothing -> record<features: list<string>, noDefaultFeatures: bool, root: string, vendor: any> { knobs-for cargo {features: [], noDefaultFeatures: false, root: ".", vendor: null} }

def feature-args [k: record]: nothing -> list<string> {
  (if $k.noDefaultFeatures { ["--no-default-features"] } else { [] }) ++ (if ($k.features | is-empty) { [] } else { ["--features" ($k.features | str join ",")] })
}

# CARGO_HOME + config.toml (vendored registry, offline, linker=cc), rustc cache wrapper, path remaps
export def --env setup []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  $env.CARGO_HOME = $"($c.build)/cargo-home"
  $env.CARGO_TARGET_DIR = $"($c.build)/target"
  mkdir $env.CARGO_HOME
  # RUSTC absolute so the wrapper (and its cache key) sees which rustc, not a bare name
  $env.RUSTC = (tool rustc)
  if ("/run/pkgs-cache.sock" | path exists) { $env.RUSTC_WRAPPER = (tool rustcwrap); $env.CARGO_INCREMENTAL = "0" }
  # vendored deps arrive as a directory (from lock.json in the real thing) nixpkgs' layout nests them one level
  let vendor = if $k.vendor != null and ($"($k.vendor)/source-registry-0" | path exists) { $"($k.vendor)/source-registry-0" } else { $k.vendor }
  let host = (^rustc -vV | lines | where { str starts-with "host:" } | first | str replace "host: " "")
  [
    (if $vendor != null { $"[source.crates-io]\nreplace-with = 'vendored'\n[source.vendored]\ndirectory = '($vendor)'" } else { "" })
    "[net]\noffline = true"
    $"[build]\njobs = ($c.njobs)"
    $"[target.($host)]\nlinker = 'cc'"
  ] | str join "\n" | save -f $"($env.CARGO_HOME)/config.toml"
  # panic strings embed source paths: map build tree, cargo home and vendor dir away.
  # our cc links with its own lld, rustc >= 1.90 would otherwise insert its bundled rust-lld
  $env.RUSTFLAGS = ([-Clinker-features=-lld $"--remap-path-prefix=($c.src)=/src" $"--remap-path-prefix=($env.CARGO_HOME)=/cargo"]
    ++ (if $vendor != null { [$"--remap-path-prefix=($k.vendor)=/vendor"] } else { [] }) | str join " ")
  cd $"($c.src)/($k.root)"
}

# cargo build --release
export def build []: nothing -> nothing { cd $"((ctx).src)/((knobs).root)"; x cargo build --release --offline ...(feature-args (knobs)) }
# cargo test --release
export def test []: nothing -> nothing { cd $"((ctx).src)/((knobs).root)"; x cargo test --release --offline ...(feature-args (knobs)) }
# every executable in target/release -> $out/bin
export def install []: nothing -> nothing {
  let c = (ctx)
  mkdir $"($c.out)/bin"
  for b in ($c.spec.bin? | default [$c.spec.name]) { cp $"($env.CARGO_TARGET_DIR)/release/($b)" $"($c.out)/bin/($b)" }
}
