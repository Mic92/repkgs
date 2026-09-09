# Plan

What design.md does not describe yet because it is not built.

## Next

**Rust from source.** Today's `rust` (upstream binaries, `prebuilt`) becomes `rust-bootstrap`,
only a build dependency of `rust`: rustc + cargo from the rustc-src tarball with `x.py` against our
LLVM (an `llvm` library package), `vendor = true`. cargo.nu and maturin take `buildPkgs.rust`,
`libgcc-shim` stays for `rust-bootstrap` only. The pin follows `rust` one release behind.
x.py's cargo-driven stages honour RUSTC_WRAPPER, but rustcwrap keys on the rustc binary: for
stage1-built crates to hit it must identify a build-tree rustc by content (binary +
librustc_driver), and stage1 must be reproducible (`rust.remap-debuginfo`, no incremental).

**Compilers that arrive as upstream binaries, from source.** The same `<x>-bootstrap` (prebuilt,
build dependency only) → `<x>` (ours) shape as go and rust for the rest. `zig`: the zig-bootstrap
tarball builds zig from source against our `llvm` library package. It is needed by bun and useful
as a package in its own right. Then `bun`: zig + our clang/lld + cmake, its vendored WebKit/JSC
built with our toolchain, `bun.lock` of its own JS parts through `fetch.bunDeps`. Large, ~1 h.
`deno`: cargo once rust is ours. The weight is `rusty_v8`, which wants a prebuilt static v8 or a
gn/ninja v8 build with our clang. Take the latter, it is the same recipe chromium-less v8 needs,
and `denort` falls out of the same build and makes `deno compile` available. `node`'s bundled
deps are swapped for ours where configure allows (`--shared-zlib/openssl/…`, partly done). Later
ecosystems follow the same rule as they arrive: `temurin` → openjdk, ghc bindist → ghc, .NET SDK
→ dotnet/runtime source-build, each prebuilt stage kept only as `<x>-bootstrap`. Until then each
prebuilt one is a build tool only (deno additionally a runtime dependency of deno applications,
since they run on it), never linked into outputs, and its sources.toml pins per-cpu archives
for x86_64 and aarch64. There are no riscv64/loongarch64/ppc64le archives upstream, so packages
using them are build-platform-only there. From-source builds lift that restriction.

**Seed 3** (building): LLVM 23.1.1 from our own pin with LoongArch and PowerPC backends.
Then loongarch64 and powerpc64le cross platforms verified (platform entries, builtins lists,
qemu targets, rust-std, GOARCH are in) and the aarch64 seed uploaded. Later the seed is built
from this set's own musl-static packages instead of nixpkgs `pkgsStatic`, fixed point in CI.

**Windows cross (x86_64/aarch64-w64-mingw32).** All-LLVM like Linux: mingw-w64 headers + CRT
as the libc recipes, compiler-rt/runtimes/cc as in stage1, `lld` for PE. A `mingw` libc flavour
in platforms.nix without interp/RUNPATH: finish/launchers treat non-ELF as done, and DLLs beside
the exe are already relocatable. `.exe` naming in install steps, `wine` as platform.emulator,
`x86_64-pc-windows-gnu`/`GOOS=windows` in cargo.nu/go.nu. No MSVC ABI (needs the unfree SDK).

**FreeBSD / NetBSD cross.** ELF and clang-native upstream, so the Linux machinery carries over:
`<cpu>-unknown-freebsd14` / `-netbsd10` triples, interp `/libexec/ld-elf.so.1` /
`/usr/libexec/ld.elf_so`, crt_interp + `$ORIGIN` + launchers unchanged, compiler-rt/runtimes with
an `os` switch instead of `linuxHeaders`. libc first as the release's `base.txz` (one hash-pinned
source per release), later built from `src.txz` (`lib/libc`, `csu`, `libthr`, `libm`). GOOS and
rust-std exist upstream. No user-mode emulator: untested builds, or a qemu-system VM job in CI.

**macOS cross (aarch64/x86_64-apple-darwin), SDK from source.** No Xcode: an `apple-sdk` recipe
assembles libSystem headers from Apple's open-source releases (xnu, Libc, libpthread,
libdispatch, Libinfo, libmalloc, libplatform, dyld, CommonCrypto, objc4, ... pinned per macOS
release, trackable by uptrack) plus committed `.tbd` link stubs, CoreFoundation from
swift-corelibs. Closed frameworks stay out of scope. Toolchain is ours: clang, `ld64.lld`
(`--adhoc_codesign`), compiler-rt, libc++/libunwind for `arm64-apple-macos11`. Relocatability
maps to `@executable_path/../lib` install names instead of RUNPATH, fixup via
`llvm-install-name-tool`, no launcher. No emulator, so cross builds are untested.

**More language ecosystems**, each an interpreter package plus a build system in the shape of
the existing ones (named native packages, applications lock their own dependency graph, one
dynamic-derivation producer reading the upstream lock file, hashes upstream lacks in `locks/`).
Lua is in (lua, luarocks, `uses = [ "luarocks" ]`, locks/luarocks.toml). `luajit` would be
`HOST_CC=cc-build` + `CROSS=` for cross. Yarn berry stays deferred: its `checksum` is over the zip yarn repacks, not the
registry tarball, so it cannot fix a fetch.

**Further ecosystems**, in this order (value per effort). Each is again interpreter + build
system + one producer, a `locks/<registry>.toml` only where the upstream lock has no usable hash,
and a sys-libs table where locked packages link C libraries.

| ecosystem | toolchain | lock → producer | notes |
|---|---|---|---|
| Yarn v1 | node (have) | `yarn.lock` `resolved`+`integrity` → offline mirror dir | next, small |
| Erlang / Elixir | erlang from C, elixir on it | `mix.lock` carries hex sha256 → `fetch.mixDeps` (`MIX_ENV=prod mix deps.get` layout), rebar3 alike | medium, clean |
| Perl CPAN | perl (have) | `cpanfile.snapshot` (carton) has no hashes → `locks/cpan.toml`. `uses = ["perl"]` for Makefile.PL/Build.PL dists | small |
| JVM (Java, Kotlin, Scala, Clojure) | `temurin` prebuilt → openjdk from source later (needs a JDK to build) | gradle `verification-metadata.xml` sha256 / maven: producer lays out an offline `~/.m2`, gradle `--offline` | large, gradle is the pain |
| Zig | zig-bootstrap → zig with our llvm (above) | `build.zig.zon` hashes → package cache dir | medium, gates bun from source |
| .NET | prebuilt SDK | `packages.lock.json` sha512 → NuGet offline feed | on demand |
| PHP | php from C (autotools, many sys-libs) | `composer.lock` dist shasum often empty → `locks/packagist.toml` | on demand |
| Haskell | ghc bindist prebuilt (self-hosting) | `cabal.project.freeze` no hashes → `locks/hackage.toml`, or stack | large |
| OCaml | from C | `opam` lock no hashes → locks table, dune builds | medium |
| R | from C + Fortran (flang from our LLVM) | `renv.lock` has hashes | science demand only |
| WebAssembly | not a language: `wasm32-wasi` as one more cross platform (clang `--target=wasm32-wasip1`, wasi-libc recipe instead of glibc, no launcher) | small, fits the cross model |

Swift (own LLVM fork), Dart/Flutter, Julia, Nim, Crystal, D: not planned.

**Lock-driven native dependencies for JS.** sys-libs.nu has tables for cargo, go, python and
gems. npm/pnpm/bun lack one for node-gyp addons (`sharp` -> libvips, `better-sqlite3`, `canvas`
-> cairo/pango). `uptrack check` should warn when a lock names a table entry whose package the
set lacks.

**Reproducibility check.** A `repro-check` job that rebuilds the set without the cache socket
(`--rebuild`) and reports CA path mismatches. diffoscope only on those.

**uptrack.** reports, `sync-github`.

**CI.** buildbot-nix/nixbot on the two build platforms plus riscv64 cross, harmonia cache with
realisations.

## Follow-ups

- jig: teach the shapes that still show as `linked`/`uncacheable` (finish.nu prints
  samples: libtool relinks, `@rsp`, multi-source lines). rustc mode can cache bin/proc-macro
  crates now that links are cached. rustc keys should not change when only the vendor store path
  does. Recurring `miss-fail` on identical rebuilds means an unstable conftest key.
- jig hashes link inputs serially. Thread it if llvm-sized links show up in profiles.
- Zig has no cache protocol (no GOCACHEPROG equivalent, `--listen` is the IDE/build server), only
  `zig-cache` directories: manifests under `h/`, artifacts under `o/<hash>/`, with the zig lib dir,
  project root and global cache dir prefix-stripped from recorded paths, so a cache dir is portable
  between sandboxes. Round-trip `ZIG_GLOBAL_CACHE_DIR` through pkgs-cache as one tree (restore
  before the build, store after, key: zig binary identity + source tree) for zig's own stage3
  first, then for a `zig` build system. Stages 1 and 2 are C through jig and cached already.
- m4's tests are off: gnulib `test-float-h.c` does not compile (C23 `*_IS_IEC_60559` missing
  from clang's `<float.h>` in gnu23 mode), and `test-posix_spawn-chdir` was seen spinning in the
  sandbox once. The spawn sequence itself passes against crt_interp outside.
