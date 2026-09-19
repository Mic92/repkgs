# rust's own phases (package.nix `modules.rust`): bootstrap.toml for x.py, then build and install through it
use core.nu *
use sys-libs.nu

# fix-shebangs edited vendored scripts: keep the crate checksums, drop the per-file ones
def vendor-checksums []: nothing -> nothing {
  for f in (files vendor/*/.cargo-checksum.json) {
    let j = (open $f | update files {{}} | to json -r)
    $j | save -f $f
  }
}

# std for these needs no libc or linker, so it ships with the compiler (as in nixpkgs)
const FREESTANDING = [wasm32-unknown-unknown wasm32v1-none bpfel-unknown-none bpfeb-unknown-none]

# x.py reads bootstrap.toml: our llvm, the rust-bootstrap binaries as stage0, one host triple.
# --env: what cargo.nu sets for the [pin] sys libraries stays for x.py's cargo runs
export def --env configure []: nothing -> nothing {
  let c = (ctx)
  load-env ({PKG_CONFIG_ALLOW_CROSS: "1"} | merge (sys-libs env-for cargo $c.deps))
  vendor-checksums
  let triple = $c.platform.rustTriple
  let rb = (tool rustc | path dirname | path dirname) # rust-bootstrap, a build tool
  let host = (^rustc -vV | lines | parse "host: {t}" | get t.0)
  {
    change-id: "ignore"
    profile: "dist"
    # use-libcxx: rustc_llvm links -lstdc++ otherwise, this toolchain has libc++ only
    llvm: {link-shared: true, download-ci-llvm: false, use-libcxx: true}
    build: {
      build: $host
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
      # dist has line tables for std only. 1 = line tables for compiler and tools too, full
      # DWARF (2) would be gigabytes
      debuginfo-level: (if $c.spec.debug { 1 } else { 0 })
      remap-debuginfo: true
      frame-pointers: true
      lld: false
      llvm-tools: false
      llvm-bitcode-linker: false
      codegen-backends: [llvm]
      codegen-tests: false # want FileCheck, which our llvm does not install
    }
    target: ({$triple: {llvm-config: (llvm-config $c), cc: (tool cc), cxx: (tool c++), linker: (tool cc), ar: (tool ar), ranlib: (tool ranlib), crt-static: false}}
      | merge (host-target $c $host --llvm)
      # rust#132802: optimized builtins for wasm want a wasm C toolchain
      | merge ($FREESTANDING | each {|t| {$t: {optimized-compiler-builtins: false, profiler: false}} } | into record))
    # include-mingw-linker would copy gcc/ld and libunwind.dll beside rustc.exe: the launcher finds it
    dist: {compression-formats: [gz], src-tarball: false, include-mingw-linker: false}
  } | to toml | save -f bootstrap.toml
}

export def build []: nothing -> nothing { x python3 x.py build --stage 2 }

export def install []: nothing -> nothing {
  let c = (ctx)
  x python3 x.py install
  # rust-installer bookkeeping, install.log carries a timestamp
  rm -f ...(files $"($c.out)/lib/rustlib/{install.log,uninstall.sh,manifest-*,components,rust-installer-version}")
}

# a cross llvm's own llvm-config is a target binary, host/llvm-config runs here (llvm/package.nix)
def llvm-config [c: record]: nothing -> string {
  let root = (dep-root llvm22 'libLLVM')
  if $c.platform.cross { $"($root)/host/llvm-config" } else { $"($root)/bin/llvm-config" }
}

# cross: the build machine's stage tools and build scripts link with its cc (and the stage1
# rustc with its libLLVM)
def host-target [c: record, host: string, --llvm]: nothing -> record {
  if not $c.platform.cross { return {} }
  let tools = {cc: (tool $env.CC_FOR_BUILD), cxx: (tool $env.CXX_FOR_BUILD), linker: (tool $env.CC_FOR_BUILD), ar: (tool llvm-ar)}
  let tools = (if $llvm { $tools | insert llvm-config $"(tool-root llvm22)/bin/llvm-config" } else { $tools })
  {$host: $tools}
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
    rust: {channel: "stable", debuginfo-level-std: (if $c.spec.debug { 1 } else { 0 }), remap-debuginfo: true, frame-pointers: true, lld: false, llvm-tools: false}
    llvm: {download-ci-llvm: false}
    target: ({$triple: {cc: (tool cc), cxx: (tool c++), linker: (tool cc), ar: (tool llvm-ar), ranlib: (tool llvm-ranlib), crt-static: false}}
      | merge (host-target $c $host))
    dist: {compression-formats: [gz], src-tarball: false}
  } | to toml | save -f bootstrap.toml
}

export def stdBuild []: nothing -> nothing { x python3 x.py build --stage 0 library }

export def stdInstall []: nothing -> nothing {
  let c = (ctx)
  # x.py install has no stage 0 path. bootstrap only recognises cargo's old target/deps layout,
  # so with the current one the stage0 sysroot gets self-contained/ and nothing else: take that,
  # and the hashed rlibs (metadata split into .rmeta) from where cargo now puts them
  let host = (^rustc -vV | lines | parse "host: {t}" | get t.0)
  let triple = $c.platform.rustTriple
  let lib = $"lib/rustlib/($triple)/lib"
  mkdir $"($c.out)/($lib | path dirname)"
  cp -r $"($c.build)/($host)/stage0-sysroot/($lib)" $"($c.out)/($lib)"
  for f in (files $"($c.build)/($host)/stage0-std/($triple)/dist/build/*/*/out/*.{rlib,rmeta,so}") { cp $f $"($c.out)/($lib)/" }
  # natively x.py builds nothing and the sysroot copy above is already the whole std
  if (files $"($c.out)/($lib)/*.rlib" | is-empty) { error make {msg: $"rust.stdInstall: no ($triple) rlibs"} }
}
