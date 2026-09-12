# Plan

What is not built yet. design.md describes what is.

## Compilers still taken as upstream binaries

Rule: an upstream binary is only ever `<x>-bootstrap`, a build dependency of `<x>` built from
source (go, rust, zig, jdk are done this way). Left:

- **bun**: zig + our clang/lld + cmake, vendored WebKit/JSC with our toolchain, its own JS
  parts through `fetch.bunDeps`. About an hour of build.
- **deno**: cargo. The weight is `rusty_v8`: build v8 with gn/ninja and our clang rather than
  take the prebuilt static lib. `denort` comes out of the same build (`deno compile`).
- **node**: swap the remaining bundled deps for ours where configure allows.

Until then these are build tools only, never linked into outputs, pinned per cpu. riscv64: bun,
deno and node have no upstream binary and do not cross-build yet (`repkgs bootstrap <x>`
uploads ours once they do); `ghc-bootstrap` is Debian's package until upstream ships a bindist
or hadrian can build a compiler for another machine.

## Platforms

- **Seed**: loongarch64 and powerpc64le end to end (backends are in). The seed built from this
  set's own static packages instead of nixpkgs, as a fixed point in CI.
- **Windows**: `.exe`/`.dll` install names, the cargo and go targets, wine as the test
  emulator. autotools stays `unsupported` there.
- **FreeBSD / NetBSD**: ELF and clang upstream, so crt_interp, `$ORIGIN` and launchers carry
  over. libc from the release's `base.txz` first, from `src.txz` later. No user-mode emulator:
  tests need a VM job.
- **macOS**: our own libc++ with `@rpath` install names, script launchers for Mach-O, pruning
  the SDK of libraries this set builds itself, a darwin builder hop for tests.
- **wasm32-wasi** as one more cross platform: wasi-libc instead of glibc, no launcher.

## Ecosystems

Each is an interpreter package, a build system module, one lock-file producer, and a
`locks/<registry>.toml` only where the upstream lock has no usable hash. In rough order of value
per effort:

| ecosystem | status / shape |
|---|---|
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

- **CI**: nixbot on both build platforms plus the cross targets, harmonia cache with
  realisations, `repkgs repro` as a job.
- **uptrack**: reports, `sync-github`.
- **builder/ blast radius**: every package hashes the whole `builder/` tree, so an edit to a
  helper two packages use (ghc-bindist.nu, node-common.nu, beam.nu) rebuilds llvm. Import
  those per package through a filtered path like package modules, keep only the framework
  (core, prepare, finish, implant, systems/) in the tree every script sees.
- **llvm install size**: `install` copies the ~200 component archives libLLVM.so was linked
  from (llvm 807 MB of .a next to a 57 MB .so, zig-llvm 1.6 GB). Nothing links them but zig's
  lld (no dylib there). `LLVM_DISTRIBUTION_COMPONENTS` + `install-distribution` installs a
  named list and writes LLVMExports.cmake to match. With the next world rebuild.

## jig follow-ups

- Teach the link shapes that still log as `linked`/`uncacheable` (libtool relinks, `@rsp`,
  multi-source lines). Cache bin and proc-macro crates in rustc mode. rustc keys must not change
  when only the vendor store path does. A recurring `compiled-error` on identical rebuilds means
  an unstable conftest key.
- Hash link inputs in parallel if llvm-sized links show up in profiles.
- **Zig cache**: zig has no cache protocol, only `zig-cache` dirs with prefix-stripped paths,
  so they are portable between sandboxes. Round-trip `ZIG_GLOBAL_CACHE_DIR` through jigd as one
  tree (key: zig binary + source tree), first for zig's own stage3, then for a zig build system.

## Builder follow-ups

- **.pyc in python outputs**: see what pip/meson installs write (`__pycache__` with source
  paths and mtimes) and pick one: delete, or recompile with `--invalidation-mode unchecked-hash`.
- **config.sub refresh**: old autotools tarballs reject riscv64/loongarch64 triples. Copy a
  current config.sub/config.guess in `autotools.configure` when cross, once a package needs it.
- **toolchain references**: `reloc-fixup --deny` the `cc` wrapper for native builds too, after
  checking which outputs record their compiler (python sysconfig, perl Config.pm) and how
  those should read instead.
- **debug through collectors**: a dyn-drv collector (cargo, cabal packages) forwards `out`
  only, the inner build's `debug` output is dropped.
- **tests/builder**: cargo, cmake, python with a C extension, npm, cabal.
- **rust cross**: std for the target triple from our llvm, cargo's linker per target.
- `dep-root --optional` and a lint for dep-root names missing from dependencies, uptrack lock
  validation at update time, `repkgs fetch-plan` (what a build would download), `repkgs debug
  <pkg>` (gdb with debug-file-directory on the package's debug output).

## Known test gaps

- m4: gnulib `test-float-h.c` does not compile with clang in gnu23 mode (C23 `*_IS_IEC_60559`),
  and `test-posix_spawn-chdir` once spun in the sandbox.
