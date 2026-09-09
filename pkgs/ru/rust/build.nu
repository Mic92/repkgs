# rust's steps (package.nix `module`): bootstrap.toml for x.py, then build and install through it
use ../../../builder/core.nu *

# x.py reads bootstrap.toml: our llvm, the rust-bootstrap binaries as stage0, one host triple
export def configure []: nothing -> nothing {
  let c = (ctx)
  # fix-env-shebangs edited vendored scripts: keep the crate checksums, drop the per-file ones
  for f in (glob vendor/*/.cargo-checksum.json) {
    open $f | update files {{}} | to json -r | save -f $f
  }
  let triple = ($c.platform.triple | str replace $c.platform.cpu $c.platform.names.rust)
  let rb = (tool rustc | path dirname | path dirname) # rust-bootstrap, a build tool
  {
    change-id: "ignore"
    profile: "dist"
    # use-libcxx: rustc_llvm links -lstdc++ otherwise, this toolchain has libc++ only
    llvm: {link-shared: true, download-ci-llvm: false, use-libcxx: true}
    build: {
      build: $triple
      host: [$triple]
      target: [$triple]
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
      lld: false
      llvm-tools: false
      llvm-bitcode-linker: false
      codegen-backends: [llvm]
      codegen-tests: false # want FileCheck, which our llvm does not install
    }
    target: {$triple: {llvm-config: $"(dep-root llvm 'libLLVM')/bin/llvm-config", cc: (tool cc), cxx: (tool c++), linker: (tool cc), ar: (tool ar), ranlib: (tool ranlib), crt-static: false}}
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
