# Plan

What is not built yet. design.md describes what is.

## Compilers still taken as upstream binaries

Rule: an upstream binary is only ever `<x>-bootstrap`, a build dependency of `<x>` built from
source (go, rust, zig, jdk are done this way). Left:

- **bun**: zig + our clang/lld + cmake, vendored WebKit/JSC with our toolchain, its own JS
  parts through `fetch.bunDeps`. About an hour of build.
- **deno**: cargo. The weight is `rusty_v8`: build v8 with gn/ninja and our clang rather than
  take the prebuilt static lib. `denort` comes out of the same build (`deno compile`).
- **ghc**: from source, booted by `ghc-bootstrap`.
- **node**: swap the remaining bundled deps for ours where configure allows.

Until then these are build tools only, never linked into outputs, pinned per cpu for x86_64 and
aarch64. riscv64/loongarch64/ppc64le have no upstream binaries, so their users are
build-platform-only there. From source lifts that.

## Platforms

- **Seed 3**: LLVM 23 with LoongArch and PowerPC backends, then loongarch64 and powerpc64le
  cross verified end to end and the aarch64 seed uploaded. Later the seed is built from this
  set's own static packages instead of nixpkgs, as a fixed point in CI.
- **Windows** (`<cpu>-windows`, MSVC ABI): the toolchain links hello.exe. Next are the build
  systems (cmake/meson/cargo target settings, `.exe`/`.dll` install names), wine as the test
  emulator, and which packages make sense there at all.
- **FreeBSD / NetBSD**: ELF and clang upstream, so crt_interp, `$ORIGIN` and launchers carry
  over. libc from the release's `base.txz` first, from `src.txz` later. No user-mode emulator:
  tests need a VM job.
- **macOS** (`aarch64-macos`): the toolchain links hello over Apple's SDK with `ld64.lld`.
  Next: our own libc++ with `@rpath` install names, pruning the SDK of libraries this set builds
  itself (zlib, curl, sqlite, libffi and friends, as nixpkgs does), the build systems' target
  settings, and a darwin builder hop for tests since Linux has no user-mode emulator for it.
- **wasm32-wasi** as one more cross platform: wasi-libc instead of glibc, no launcher.

## Ecosystems

Each is an interpreter package, a build system module, one lock-file producer, and a
`locks/<registry>.toml` only where the upstream lock has no usable hash. In rough order of
value per effort:

| ecosystem | status / shape |
|---|---|
| Erlang, Elixir | erlang from C. `mix.lock` has hex sha256 → `fetch.mixDeps`. rebar3 alike |
| Perl CPAN | perl is in. `cpanfile.snapshot` has no hashes → `locks/cpan.toml` |
| JVM (gradle, maven) | jdk is in. gradle `verification-metadata.xml` / maven → offline `~/.m2`. gradle is the hard part |
| .NET | prebuilt SDK → source-build later. `packages.lock.json` sha512 → NuGet offline feed |
| PHP | php from C. `composer.lock` shasums often empty → `locks/packagist.toml` |
| OCaml | from C. opam locks have no hashes → locks table, dune builds |
| R | from C and Fortran (flang). `renv.lock` has hashes |
| luajit | `HOST_CC=cc-build` + `CROSS=` for cross |

Not planned: Swift (own LLVM fork), Dart/Flutter, Julia, Nim, Crystal, D. Yarn berry stays out:
its checksum is over a zip yarn repacks, not the registry tarball.

**Native dependencies for JS locks.** sys-libs.nu covers cargo, go, python, gems. node-gyp
addons (`sharp` → libvips, `better-sqlite3`, `canvas` → cairo/pango) need the same table for
npm/pnpm/bun, and `uptrack check` should warn when a lock names a library the set lacks.

## Infrastructure

- **Reproducibility**: a CI job running `repkgs repro` (rebuild without the cache socket,
  report CA path mismatches, diffoscope those).
- **CI**: nixbot on both build platforms plus riscv64 cross, harmonia cache with realisations.
- **uptrack**: reports, `sync-github`.

## jig follow-ups

- Teach the link shapes that still log as `linked`/`uncacheable` (libtool relinks, `@rsp`,
  multi-source lines). Cache bin and proc-macro crates in rustc mode. rustc keys must not change
  when only the vendor store path does. A recurring `compiled-error` on identical rebuilds means
  an unstable conftest key.
- Hash link inputs in parallel if llvm-sized links show up in profiles.
- **Zig cache**: zig has no cache protocol, only `zig-cache` dirs with prefix-stripped paths,
  so they are portable between sandboxes. Round-trip `ZIG_GLOBAL_CACHE_DIR` through jigd as one
  tree (key: zig binary + source tree), first for zig's own stage3, then for a zig build system.

## Known test gaps

- m4: gnulib `test-float-h.c` does not compile with clang in gnu23 mode (C23 `*_IS_IEC_60559`),
  and `test-posix_spawn-chdir` once spun in the sandbox.
