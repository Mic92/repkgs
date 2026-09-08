# Plan

What design.md does not describe yet because it is not built. `standins.nix` is gone: every build
tool is a package; nixpkgs remains only in shell.nix/treefmt.nix and pkgs/se/seed/build.nix.

## Next

**Rust from source.** Today's `rust` (upstream binaries, `prebuilt`) becomes `rust-bootstrap`,
only a build dependency of `rust`: rustc + cargo from the rustc-src tarball with `x.py` against our
LLVM (an `llvm` library package), `vendor = true`. cargo.nu and maturin take `buildPkgs.rust`,
`libgcc-shim` stays for `rust-bootstrap` only. The pin follows `rust` one release behind.

**goModules without a vendor hash.** go.sum's `h1:` is a dirhash, not a file hash, so uptrack's
locks stage writes `lock.json` (module → zip sha256) from go.sum; goModules then becomes dynamic
like cargoVendor (one fetchurl per zip + an assemble step). Go is that stage's first user; npm and
cargo need nothing.

**Python beyond the build stack**, with the first application: no generated library set. Named
packages are the interpreter, the build stack, native extensions that must link our libraries,
and the few pure libraries C projects import at build time. Applications bring `uv.lock` and
`fetch.pythonDeps { source }` is a dynamic derivation like cargoVendor.

**Seed 3.** Built from this set's own packages for a musl-static platform instead of nixpkgs
`pkgsStatic`; add a static curl + the CA bundle so a source becomes one fixed-output derivation
(fetch + unpack) instead of fetchurl + unpack. aarch64 seed uploaded. Size levers: nu without
polars/sqlite, LLVM with three targets. Fixed-point check in CI.

**Reproducibility check.** A `repro-check` job that rebuilds the set without the cache socket
(`--rebuild`) and reports CA path mismatches; diffoscope only on those.

**uptrack.** Lock generation for `fetch.*Deps` packages, reports, `sync-github`.

**CI.** buildbot-nix/nixbot on the two build platforms plus riscv64 cross, harmonia cache with
realisations.

## Follow-ups

- jig: teach the shapes that still show as `plain-link`/`plain-compile` (finish.nu prints
  samples: libtool relinks, `@rsp`, multi-source lines); rustc mode can cache bin/proc-macro
  crates now that links are cached; rustc keys should not change when only the vendor store path
  does; recurring `miss-fail` on identical rebuilds means an unstable conftest key.
- jig hashes link inputs serially; thread it if llvm-sized links show up in profiles.
- Cache store: measure FastCDC chunks + pack files against one LZ4 blob per key
  (experiments/cdc) before changing pkgs-cache's layout.
- m4's gnulib `test-posix_spawn-chdir` spins in the sandbox: check crt_interp's AT_EXECFN
  fallback when cwd changes.
- nodejs, glib, qemu: first builds in flight; cross builds (riscv64, aarch64) to re-verify after
  the unpack-once change.
