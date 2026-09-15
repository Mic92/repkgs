use ../core.nu *
use ../sys-libs.nu

# cargo build/test/install, offline against a vendored registry snapshot. rustc goes through jig's cache.
export const OPTIONS = {
  features: {default: [], doc: "--features"}
  noDefaultFeatures: {default: false, doc: "--no-default-features"}
  flags: {default: [], doc: "extra arguments for cargo build and cargo test"}
  skipTests: {default: [], doc: "cargo test --skip filters (substring of the test path)"}
  cratePatches: {default: {}, doc: "crate name -> patches applied to its vendored copy (-p1 inside the crate)"}
}

# features and `cargo.flags`, for build and test alike
def args [o: record<features: list<string>, noDefaultFeatures: bool, flags: list<string>>]: nothing -> list<string> {
  [
    (if $o.noDefaultFeatures { "--no-default-features" })
    (if ($o.features | is-not-empty) { $"--features=($o.features | str join ',')" })
  ] | compact | append $o.flags
}

# CARGO_HOME + config.toml (vendored registry, offline, linker=cc), path remaps
export def --env setup []: nothing -> nothing {
  let o = (options cargo)
  let vendor = (if ($o.cratePatches | is-empty) { $o.deps } else { patched-vendor $o.deps $o.cratePatches })
  sys-libs check (project-dir cargo) (ctx).spec.sys
  configure $vendor $"((ctx).build)/cargo-home"
}

# Also used for a cargo run inside another build system (pyapp's Rust sdists). `vendor` is null
# when the source vendors its own crates, `home` becomes CARGO_HOME
export def --env configure [vendor: any, home: string]: nothing -> nothing {
  let c = (ctx)
  load-env {CARGO_HOME: $home, CARGO_TARGET_DIR: $"($c.build)/target", RUSTC: (tool rustc)}
  mkdir $env.CARGO_HOME
  let host = (^rustc -vV | lines | parse "host: {t}" | get t.0)
  let target = $c.platform.rustTriple
  $env.CARGO_BUILD_TARGET = $target
  # -sys crates: link our libraries (builder/sys-libs.nu). pkg-config, their usual probe,
  # refuses to answer under --target without ALLOW_CROSS
  let sys = (sys-libs env-for cargo $c.deps)
  load-env ({PKG_CONFIG_ALLOW_CROSS: "1"} | merge $sys)
  if ($sys | is-not-empty) { note sys-libs ($sys | columns | str join " ") }
  # bindgen asks a clang executable for its include dirs: ours, not a bare one found on PATH
  $env.CLANG_PATH = (which cc | get 0.path)
  # cross: the toolchain carries std for the build machine only, the target's is <toolchain>-std
  # (cargo.tools): one sysroot of symlinks over both
  let sysroot = (if $c.platform.cross {
    let s = $"($c.build)/rust-sysroot"
    let std = (tool-root $"((exports-of (tool rustc | path dirname -n 2)).name)-std")
    mkdir $"($s)/lib/rustlib"
    for d in (ls $"(tool rustc | path dirname -n 2)/lib/rustlib" | get name) { ^ln -s $d $"($s)/lib/rustlib/" }
    ^ln -s $"($std)/lib/rustlib/($target)" $"($s)/lib/rustlib/"
    [$"--sysroot=($s)"]
  } else { [] })
  # rustflags in config (RUSTFLAGS from the environment would replace them): panic strings embed
  # source paths, map build tree, cargo home and vendor dir away. Frame pointers like the C side
  # `deps` null: the source vendors (or has no) dependencies. An empty FROM would match every path
  let remap = ({"/src": $c.src, "/cargo": $env.CARGO_HOME, "/vendor": $vendor} | items {|to, from| if $from != null { $"--remap-path-prefix=($from)=($to)" } } | compact)
  let rustflags = ($remap ++ ["-Cforce-frame-pointers=yes"] ++ $sysroot)
  let source = (if $vendor == null { {} } else { {source: {crates-io: {replace-with: vendored}, vendored: {directory: $vendor}}} })
  $source | merge {
    net: {offline: true}
    build: {jobs: $c.njobs}
    # host first: natively it is the target and cc wins
    target: ({} | upsert $host {linker: $env.CC_FOR_BUILD, rustflags: $rustflags} | upsert $target {linker: cc, rustflags: $rustflags})
  } | to toml | save -f $"($env.CARGO_HOME)/config.toml"
  hide-env -i RUSTFLAGS
}

# the vendor dir with the named crates copied out and patched, the rest symlinked
def patched-vendor [deps: string, patches: record]: nothing -> string {
  let dir = $"((ctx).build)/vendor"
  mkdir $dir
  let names = (ls -s $deps | get name)
  for n in $names { ^ln -s $"($deps)/($n)" $"($dir)/($n)" }
  for p in ($patches | transpose crate files) {
    let hits = ($names | where { ($in | parse -r '^(?<n>.+)-\d[^-]*$' | get -o n.0) == $p.crate })
    if ($hits | is-empty) { error make {msg: $"cargo.cratePatches: no vendored crate ($p.crate)"} }
    for n in $hits {
      rm $"($dir)/($n)"
      ^cp -r $"($deps)/($n)" $"($dir)/($n)"
      ^chmod -R u+w $"($dir)/($n)"
      for f in $p.files { note patch $"($n): ($f)"; ^patch -d $"($dir)/($n)" -p1 -F0 -i $f }
    }
  }
  $dir
}

export def workdir []: nothing -> string { project-dir cargo }

# cargo build --release
export def build []: nothing -> nothing { x cargo build --release --offline ...(args (options cargo)) }
# cargo test --release, tests.parallel as --test-threads, cargo.skipTests as --skip filters
export def test []: nothing -> nothing {
  let o = (options cargo)
  x cargo test --release --offline ...(args $o) -- --test-threads (test-jobs) ...($o.skipTests | each { [--skip $in] } | flatten)
}
# the executables cargo built -> $out/bin (those in `bin` when the spec names some), as go does
export def install []: nothing -> nothing {
  let c = (ctx)
  # with CARGO_BUILD_TARGET set cargo always builds into target/<triple>/
  let release = $"($env.CARGO_TARGET_DIR)/($env.CARGO_BUILD_TARGET)/release"
  # cargo's own files there: lib*.rlib/.so/.d and .cargo-lock; the rest are the [[bin]] targets
  let built = (ls -s $release | where type == file and name !~ '^lib|\.(d|rlib|pdb)$|^\.' | get name)
  let exe = $c.platform.ext.exe
  install-bins $release ($built | where { $c.spec.bin? == null or ($in | str replace -r $'\($exe)$' "") in $c.spec.bin })
}
