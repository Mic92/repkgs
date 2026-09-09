# rustc + cargo + std from the rustc-src tarball, x.py driven by `rust-bootstrap` (upstream
# binaries, build-only), codegen through our libLLVM. std for the build machine's triple only:
# cross stds need each target's cc as x.py linker, later.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "rust";
  dependencies = [
    pkgs.llvm
    pkgs.zlib
    pkgs.openssl # cargo
  ];
  env.OPENSSL_NO_VENDOR = "1"; # cargo's openssl-sys: ours via pkg-config, not a vendored build
  buildDependencies = [
    buildPkgs.rust-bootstrap
    buildPkgs.cpython
    buildPkgs.cmake
    buildPkgs.ninja
    buildPkgs.pkgconf
  ];
  steps = [
    {
      name = "configure";
      run = ''
        let triple = ($c.platform.triple | str replace $c.platform.cpu $c.platform.names.rust)
        let rb = (tool rustc | path dirname | path dirname) # rust-bootstrap, a build tool
        {
          change-id: "ignore"
          profile: "dist"
          llvm: {link-shared: true, download-ci-llvm: false}
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
          }
          install: {prefix: $c.out, sysconfdir: "etc"}
          rust: {
            channel: "stable"
            remap-debuginfo: true
            lld: false
            llvm-tools: false
            llvm-bitcode-linker: false
            codegen-backends: [llvm]
            description: "pkgs"
          }
          target: {$triple: {llvm-config: $"(dep-root llvm 'libLLVM')/bin/llvm-config", cc: (tool cc), cxx: (tool c++), linker: (tool cc), ar: (tool ar), ranlib: (tool ranlib), crt-static: false}}
          dist: {compression-formats: [gz], src-tarball: false}
        } | to toml | save -f bootstrap.toml
      '';
    }
    {
      name = "build";
      run = "x python3 x.py build --stage 2";
    }
    {
      name = "install";
      run = ''
        x python3 x.py install
        # rust-installer bookkeeping, install.log carries a timestamp
        rm -f ...(glob $"($c.out)/lib/rustlib/{install.log,uninstall.sh,manifest-*,components,rust-installer-version}")
      '';
    }
  ];
  tests.run = false; # x.py test: hours
  bin = [
    "rustc"
    "cargo"
  ];
  tests.version = "-V";
  tests.relocated = true;
  exports = false;
}
