# Design

What the tree does today and why. Measurements that led here are in `experiments/` (kept as
they were run; they import nixpkgs, the tree does not). What is not built yet is in plan.md, not here.

## 0. Scope

Goals, in priority order:

1. Cheap evaluation: ≤0.2 ms and ≤10 KB per package (nixpkgs ≈2.6 ms / 135 KB per drv).
2. Relocatable outputs: no output contains its own store path, dependencies are referenced
   relative to the output, so floating content-addressed outputs and early cut-off are the default.
3. nushell as the builder language; the binary seed is a handful of static executables.
4. One LLVM toolchain for all targets; cross compilation is an argument to the set.
5. A compile cache in the compiler entry point, so incremental work on the set is cheap.

Constraints: stock Nix with `ca-derivations dynamic-derivations`, normal `/nix/store` via the
daemon, no IFD, no fetching at eval time. glibc is the libc; musl only for the static seed and
stage0. Build platforms x86_64-linux and aarch64-linux; riscv64-linux is cross-only. CPU
baseline is part of the platform: x86-64-v3, armv8.2-a+lse, rv64gc (`nix/platforms.nix`); the
cc conf injects `-march`, there are no per-package `-march` flags and no hwcaps subdirectories.
nixpkgs appears only in `shell.nix`/`treefmt.nix` (dev tools) and `pkgs/se/seed/build.nix`.

Out of scope: NixOS modules, nixpkgs API compatibility, hex0 bootstrap, GCC as system compiler,
darwin.

## 1. Evaluation

**Packages are functions returning a spec; `package` turns the spec into one derivation.** No
module system, no `callPackage`/`makeOverridable`, no overlays (exp. eval-cost: plain attrsets
0.44 s / 38 MB for 5000 packages, `evalModules` per package 5.8 s / 1.4 GB).

```
pkgs/zl/zlib/package.nix     attribute name == directory name, sharded by two letters
pkgs/zl/zlib/sources.toml    upstream pin read with fromTOML (docs/uptrack.md)
pkgs/cp/cpython314/          a second language line is a second package; pkgs/aliases.toml maps cpython -> cpython314
```

`default.nix { platform }` walks `pkgs/*/*` with `readDir` and calls each `package.nix` with the
scope names it asks for (`package pkgs buildPkgs platform fetch sources toolchain`). Values are
lazy: `-A jq` imports one file. `buildPkgs` is the set for the build machine (itself when
native). There are no nested sets: other platforms are `import ./. { platform = … }`, library
universes are lock-driven fetchers per application (below).

`nix/package.nix` checks field and knob names (unknown → eval error), then emits one derivation
with structured attrs whose builder is `nu -c "<script>"`: `use core.nu *; use <bs>.nu; prepare;
<bs> setup; <steps…>; finish`. Everything context-free (knobs, steps, env, exports) travels as
one `spec` JSON attribute; each dependency appears once as a path. That is the drv shape
`derivationStrict` is cheapest on (exp. proto: 0.36 s / 10 MB for 1000 packages, cross the same).

**Sources.** `sources.toml` holds URL template, hash and pin; `nix/sources.nix` turns it into
`<nix/fetchurl.nix>` (builtin, no seed needed) named after the URL's basename, so a version bump
with a stale hash cannot resolve to an old `(name, hash)` path. Archives are then unpacked once by a
small content-addressed derivation (seed bsdtar) and builds copy the tree; `unpack = false` keeps
single files. Ecosystem lock files are not copied into the repo and get no hash of ours:
`fetch.cargoVendor`/`fetch.npmDeps { source }` are dynamic derivations whose producer reads the
lock file from the source and writes one `builtin:fetchurl` per crate/tarball plus a collector,
through jig's own worker-protocol client (`jig nix-store`, no `nix` binary, no recursive-nix).
`fetch.goModules` stays one fixed-output `go mod vendor` (go.sum hashes trees, not zips) with
module zips served from the build cache and a go.sum staleness check.

## 2. Relocatable outputs

Rule: an output references other store objects only relative to itself; the store stays flat, so
from depth *d* a dependency is `$ORIGIN` + `../`×(d+1) + `<hash>-<name>/…`. The hash still
appears literally, so the reference scanner, GC and `nix copy` work unchanged.

| reference | mechanism |
|---|---|
| ELF RUNPATH | jig (as `cc`) emits absolute store RUNPATH entries for exactly the directories that satisfy a `-l`, plus libc and the C++ runtimes, plus build-tree rpaths the build system asked for; `reloc-fixup` rewrites the same bytes `$ORIGIN`-relative for the file's depth. No patchelf, no layout changes. |
| PT_INTERP | linked with an absolute `--dynamic-linker` and `crt_interp.o` (pkgs/cr/crt-interp). fixup makes `.interp` file-relative, flips the phdr to `PT_NULL` and points `e_entry` at the stub, which maps ld.so relative to `/proc/self/exe` at startup and jumps into it. glibc unmodified, `ldd` works, +0.09 ms per exec. |
| glibc data | gconv/locale found relative to the loaded `libc.so.6` (one patch); no `ld.so.cache`. |
| scripts, wrappers | one static `launch` binary (pkgs/la/launch): `bin/foo` → `launch`, record `bin/.foo.launch` (program, args, env with `{root}`/`{store}` templates), real file `bin/.foo`. Replaces shebang patching and makeWrapper. |
| upstream binaries | `prebuilt = true`: not patched, launch runs them as `ld.so --argv0 … --library-path … bin/.foo` (rust, go-bootstrap). |
| dlopen-only deps | `runtimeDependencies`: linked as DT_NEEDED so scanner and relocation see them. |
| debug info | always `-g`; finish.nu splits DWARF to `lib/debug` with a relative debuglink, keeps `.symtab`. |
| pkg-config, cmake | `${pcfiledir}`-relative / relative by default; `.la` deleted. |
| exported env | `exports.json` values may use `{root}`, expanded by the consumer (cacert's `SSL_CERT_FILE`). |
| compiled-in prefix | packages that need it get dirname-relative patches (openssl providers); the rest is caught by fixup's absolute-store-ref warning and `tests.relocated` (run `bin/x --version` from a copied prefix). |

Ambient data (CA bundle, tz, locales) is never compiled in as a store path: env var first,
conventional system path second.

## 3. Builders

nushell replaces setup.sh. One nu process per build runs `prepare` (env, unpack/copy, patch),
the build system's verbs, and `finish` (checks, debug split, launchers, reloc-fixup, version
check, exports.json, cache summary). `builder/`:

```
core.nu prepare.nu finish.nu launchers.nu     shared
autotools.nu cmake.nu meson.nu cargo.nu go.nu python.nu npm.nu   one module per build system
fetch-cargo.nu fetch-npm.nu                   dynamic-derivation producers
```

- **No generic builder, no phases, no hooks** (blind LLM test over five API variants, exp.
  builder-api). A package says `uses = [ "cmake" ]`; `steps` defaults to that build system's list
  and is required when several are used. Entries are `"<bs>.<verb>"` or `{ name; run = "<nu>"; }`.
  Knobs are namespaced and checked per build system (`autotools.flags`, `cmake.defs`,
  `meson.options`, `cargo.features`, `go.tags`, …; the table is `nix/build-systems.nix`).
- Dependencies contribute data, never behaviour: each output carries `exports.json`
  (`includeDirs libDirs libs pkgconfigDirs aclocalDirs env propagate`, defaults derived from the
  tree), and `prepare` renders the closure into CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH/CMAKE_PREFIX_PATH.
  `exports.propagate` makes propagated packages real inputs.
- Dependency kinds: `buildDependencies` (build platform, on PATH), `dependencies` (target,
  visible to the compiler), `runtimeDependencies` (target, exec'd/dlopen'd). No six-way lists.
- Defaults every package gets: `-O2 -g`, frame pointers, `_FORTIFY_SOURCE=3`,
  stack-protector-strong, stack-clash-protection, trivial-auto-var-init=zero, `-Werror=date-time`,
  relro/now/noexecstack/as-needed; `-march` and `-fcf-protection`/`-mbranch-protection` come from
  the cc conf so build systems that ignore CFLAGS still get them; libc++ is built hardened.
  Reproducibility pins: `SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C PYTHONHASHSEED=0 PERL_HASH_SEED=0
  ZERO_AR_DATE KBUILD_*`, `-ffile-prefix-map` for build dir and every dependency (handed to jig
  out of band so recorded CFLAGS stay clean), man/info pages uncompressed.
- Tests run in the build by default; `tests.separate` moves them to a second derivation that
  restores the build tree; `tests.version` checks `bin/x --version` prints the pinned version.
- `bootstrapTools = true` builds the GNU userland itself with only the seed on PATH; everything
  else gets coreutils/sed/grep/gawk/findutils/diffutils/patch/make/bash/pkgconf from the set.

## 4. jig: compiler entry point and build cache

`pkgs/ji/jig` is a static C++ binary dispatching on argv[0]: `cc c++ cpp` (driver policy +
cache), `rustc` (RUSTC_WRAPPER), `gocacheprog` (Go's external cache protocol), `reloc-fixup`,
`nix-store` (worker protocol for dynamic derivations), `jig cache get|put` (blobs). It is the only
compiler on PATH, so every build system goes through it unchanged.

As driver it adds `--target --sysroot -fuse-ld=lld`, compiler-rt/libunwind/libc++, the platform
flags, prefix maps, the RUNPATH policy and `crt_interp.o`. As cache it talks to
`/run/pkgs-cache.sock` if present (the daemon maps the host socket in with `extra-sandbox-paths`;
no socket → plain compile, derivations never mention the cache):

| cached | key |
|---|---|
| `cc -c x.c` | tool store path + normalised args + source bytes; headers by hash-masked store name or content, list learned from `-MD` on the first miss (manifest) |
| `cc x.c -o x` probes, `cc *.o *.a -o x` links | as above over object InputIds; lld `--dependency-file` supplies libraries and linker scripts |
| compile failures with all inputs known | replayed as failures (configure probes) |
| rustc crates | args + dep-info inputs + `--extern` hashes |
| Go actions | Go's own action IDs (GOCACHEPROG) |
| autoconf `config.cache`, cmake probe results | sha256 of the scripts + masked toolchain/dependency set + platform + flags + `$out` |
| go module zips | `gomod/<mod>@<ver>/<h1>` |

Values are LZ4-compressed by the client. Store identity is by content, so a rebuilt-but-identical
toolchain still hits. The host side is `pkgs/pk/pkgs-cache` (Go, blobs under
`$XDG_CACHE_HOME/pkgs-cache`). Trust: cache writers can inject code; CA outputs make that
detectable by rebuilding without the socket.

## 5. Toolchain, bootstrap, cross

```
seed.nar.xz   static-pie musl: nu, LLVM multicall (clang, lld, llvm-*), bsdtar, toybox, dash, make,
              gawk sed grep m4 bison, minimal python   (pkgs/se/seed, fetched with <nix/fetchurl.nix> unpack)
  → stage0 (musl, PATH = seed): musl-headers, compiler-rt, musl, linux-headers, runtimes, jig, cc
  → stage1 (glibc, per platform, built by stage0 cc through jig): linux-headers, glibc,
    compiler-rt, runtimes, sysroot-<triple> (symlink view), cc-<platform> (jig + etc/jig.conf), launch
  → packages
```

Recipes are nu (`pkgs/*/bootstrap.nu`, `pkgs/ll/llvm/{compiler-rt,runtimes,cc}.nu`): musl,
compiler-rt and the C++ runtimes are compiled from file lists without cmake; glibc and the kernel
headers use their own build systems under the seed's dash/make. The only vendored generated input
is compiler-rt's per-cpu builtins list (`pkgs/ll/llvm/update.nu`).

One LLVM per build machine; a target is kernel headers + glibc + compiler-rt + runtimes (~5 min).
Cross is `import ./. { platform = "riscv64-linux"; }`: same code path, `buildPkgs` is the native
set, build systems get `--host`/toolchain file/cross file/`CARGO_TARGET_*`/GOARCH from the
platform record, tests run under `buildPkgs.qemu` where the harness has a hook (cmake, meson,
cargo, go) and are reported "untested" otherwise unless the builder has transparent binfmt.
Language toolchains bootstrap from upstream binaries run as `prebuilt` packages (`go-bootstrap`
→ `go` from source; `rust` is still the upstream binary, plan.md 5b).

## 6. Updates

`pkgs/up/uptrack`: purl-driven datasources, one batched cached poll, `sources.toml` as the only
file it writes, optional per-package hook. docs/uptrack.md.

## 7. Where the numbers came from

| exp. | question | answer |
|---|---|---|
| eval-cost, lib-bench, proto | eval cost of package abstraction | plain functions, one JSON spec attr: 0.36 s / 1000 packages |
| ldwrap, reloc-interp | relocatable ELF without patching ld.so | link-time `crt_interp.o` + RUNPATH policy + in-place fixup; x86_64/aarch64/riscv64 |
| cc-cache | compile cache inside the sandbox | socket via `extra-sandbox-paths`; sqlite3.c 82 s → 0.08 s, fd's rlibs 218 s → 1.4 s, bit-identical |
| nu-noshell, seed | can nu + clang build without sh/make; own seed | yes for musl/compiler-rt/libc++/dash/toybox; 60 MB nar.xz, stage0 → cc in 6 min |
| builder-api | builder API | build systems as nu modules + name-only step list won 15/15 |
| glibc-clang | glibc with clang/lld | 2.43+; a few GCC-only configure probes pinned |
| platforms | one LLVM for all targets | target is a flag; lld RISC-V relaxation vs IRELATIVE needs `-mno-relax` |

Prior art used: Ekala EEPs (path = attr, explicit build systems), Aux tidepool (eval-time
exports, one code path for native and cross), nuenv, zig (target as flag), Spack/Guix/conda
(relocation), wrap-buddy and fzakaria (relocatable binaries, DT_NEEDED hardening), llm-agents.nix
(declarative updater).
