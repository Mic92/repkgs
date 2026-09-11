# rust's own phases (package.nix `modules.rust`): bootstrap.toml for x.py, then build and install through it
use core.nu *

# fix-env-shebangs edited vendored scripts: keep the crate checksums, drop the per-file ones
def vendor-checksums []: nothing -> nothing {
  for f in (glob vendor/*/.cargo-checksum.json) {
    let j = (open $f | update files {{}} | to json -r)
    $j | save -f $f
  }
}

# std for these needs no libc or linker, so it ships with the compiler (as in nixpkgs)
const FREESTANDING = [wasm32-unknown-unknown wasm32v1-none bpfel-unknown-none bpfeb-unknown-none]

# x.py reads bootstrap.toml: our llvm, the rust-bootstrap binaries as stage0, one host triple
export def configure []: nothing -> nothing {
  let c = (ctx)
  vendor-checksums
  let triple = $c.platform.rustTriple
  let rb = (tool rustc | path dirname | path dirname) # rust-bootstrap, a build tool
  {
    change-id: "ignore"
    profile: "dist"
    # use-libcxx: rustc_llvm links -lstdc++ otherwise, this toolchain has libc++ only
    llvm: {link-shared: true, download-ci-llvm: false, use-libcxx: true}
    build: {
      build: $triple
      host: [$triple]
      target: ([$triple] ++ $FREESTANDING)
      rustc: $"($rb)/bin/rustc"
      cargo: $"($rb)/bin/cargo"
      docs: false
      extended: true
      tools: [cargo clippy rustfmt rustdoc rust-analyzer-proc-macro-srv]
      vendor: true
      locked-deps: true
      build-dir: $c.build
      jobs: $c.njobs
      optimized-compiler-builtins: false
      description: "repkgs" # `rustc --version` names its builder
    }
    install: {prefix: $c.out, sysconfdir: "etc"}
    rust: {
      channel: "stable"
      remap-debuginfo: true
      frame-pointers: true
      lld: false
      llvm-tools: false
      llvm-bitcode-linker: false
      codegen-backends: [llvm]
      codegen-tests: false # want FileCheck, which our llvm does not install
    }
    target: ({$triple: {llvm-config: $"(dep-root llvm22 'libLLVM')/bin/llvm-config", cc: (tool cc), cxx: (tool c++), linker: (tool cc), ar: (tool ar), ranlib: (tool ranlib), crt-static: false}}
      # rust#132802: optimized builtins for wasm want a wasm C toolchain
      | merge ($FREESTANDING | each {|t| {$t: {optimized-compiler-builtins: false, profiler: false}} } | into record))
    dist: {compression-formats: [gz], src-tarball: false}
  } | to toml | save -f bootstrap.toml
}

export def build []: nothing -> nothing { x python3 x.py build --stage 2 }

export def install []: nothing -> nothing {
  let c = (ctx)
  x python3 x.py install
  # rust-installer bookkeeping, install.log carries a timestamp
  rm -f ...(glob $"($c.out)/lib/rustlib/{install.log,uninstall.sh,manifest-*,components,rust-installer-version}")
}

# rust-std: the installed rust as stage0, std for the target only, linked with the target cc
export def stdConfigure []: nothing -> nothing {
  let c = (ctx)
  vendor-checksums
  let host = (^rustc -vV | lines | parse "host: {t}" | get t.0)
  let triple = $c.platform.rustTriple
  let rust = (tool rustc | path dirname -n 2)
  {
    change-id: "ignore"
    profile: "dist"
    build: {
      build: $host
      host: []
      target: [$triple]
      rustc: $"($rust)/bin/rustc"
      cargo: $"($rust)/bin/cargo"
      local-rebuild: true
      docs: false
      vendor: true
      locked-deps: true
      build-dir: $c.build
      jobs: $c.njobs
      optimized-compiler-builtins: false
    }
    install: {prefix: $c.out, sysconfdir: "etc"}
    rust: {channel: "stable", remap-debuginfo: true, frame-pointers: true, lld: false, llvm-tools: false}
    llvm: {download-ci-llvm: false}
    target: ({$triple: {cc: (tool cc), cxx: (tool c++), linker: (tool cc), ar: (tool llvm-ar), ranlib: (tool llvm-ranlib), crt-static: false}}
      | merge (if $c.platform.cross { {$host: {cc: (tool cc-build), cxx: (tool c++-build), linker: (tool cc-build), ar: (tool llvm-ar)}} } else { {} }))
    dist: {compression-formats: [gz], src-tarball: false}
  } | to toml | save -f bootstrap.toml
}

export def stdBuild []: nothing -> nothing { x python3 x.py build --stage 0 library }

export def stdInstall []: nothing -> nothing {
  let c = (ctx)
  # x.py install has no stage 0 path. bootstrap only recognises cargo's old target/deps layout,
  # so with the current one the stage0 sysroot gets self-contained/ and nothing else: take that,
  # and the hashed rlibs from where cargo now puts them
  let host = (^rustc -vV | lines | parse "host: {t}" | get t.0)
  let triple = $c.platform.rustTriple
  let lib = $"lib/rustlib/($triple)/lib"
  mkdir $"($c.out)/($lib | path dirname)"
  cp -r $"($c.build)/($host)/stage0-sysroot/($lib)" $"($c.out)/($lib)"
  let built = (glob $"($c.build)/($host)/stage0-std/($triple)/dist/build/*/*/out/*.{rlib,so}")
  if ($built | is-empty) { error make {msg: "rust.stdInstall: no target rlibs under stage0-std"} }
  for f in $built { cp $f $"($c.out)/($lib)/" }
}
