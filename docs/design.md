# Design

What the set does differently from nixpkgs and why. Things not built yet are in `plan.md`,
the updater in `uptrack.md`.

Names used below: **jig** is the compiler driver (`cc`, `c++`, `rustc` on the build `PATH`) and
ELF post-processor, **jigd** the per-machine daemon behind it (compile cache, build slots),
**launch** the one binary behind every installed script, **uptrack** the updater.

## Goals

1. **Cheap evaluation.** ≤ 0.2 ms and 10 KB per package (nixpkgs: 2.6 ms, 135 KB).
2. **Relocatable outputs.** No output contains its own store path. Every derivation is
   content-addressed, so early cut-off works by default, and a closure runs from any directory.
3. **Nushell builders.** Structured data, real errors, and a seed of a few static binaries.
4. **One toolchain.** One LLVM targets every platform. Cross is an argument to the set.
5. **A compile cache under Nix.** Editing a recipe recompiles what changed, not everything after it.

Constraints: stock Nix with `ca-derivations` and `dynamic-derivations`, `/nix/store`, no IFD,
nothing fetched at eval time. glibc everywhere, musl only in the seed and stage0. nixpkgs builds
the seed and provides dev tools, nothing else. Not goals: NixOS modules, nixpkgs compatibility,
full-source bootstrap, GCC.

Build machines are x86_64- and aarch64-linux. riscv64, loongarch64, ppc64le, Windows (MSVC ABI
over Microsoft's CRT and SDK) and macOS (Apple's SDK, `ld64.lld`) are cross targets. For the two
non-Linux ones only compiler-rt is ours. The CPU baseline (x86-64-v3, armv8.2-a+lse, rv64gc) is
part of the platform and injected by jig, so no package carries `-march`.

## Evaluation

A package is a function returning a small attrset, the *spec*. `nix/package.nix` checks it
(unknown field, unknown or mistyped option → error) and makes one derivation whose builder is
`nu -c <script>`, with everything that is not a dependency in one JSON attribute. No
`callPackage`/`mkDerivation`/module layers, no per-package fixpoint: 1000 packages evaluate in
0.36 s and 10 MB, native or cross.

```
pkgs/zl/zlib/package.nix     attribute = directory name, two-letter shards
pkgs/zl/zlib/sources.toml    upstream pin (url template, version, hash)
pkgs/cp/cpython314/          another major version is another package, pkgs/aliases.toml maps cpython → cpython314
```

`import ./. { platform }` lists `pkgs/` and calls each `package.nix` with what it names
(`package variant pkgs buildPkgs platform fetch sources toolchain`). It is lazy: `nix-build -A jq`
reads one file. `buildPkgs` is the build machine's set. Another platform is another import.

Every package exists on every platform. `pkg.supported` says whether it is *for* it, without
forcing the derivation: prebuilts are for the cpus their `sources.toml` has tarballs for, a
recipe can narrow with `platforms.cpu` or `platforms.cross = false`, and unsupported
dependencies propagate. Only the store paths throw (`bun: sources.toml has no 'riscv64' source`), so CI filters on a boolean instead of
`tryEval`, which would also hide real errors.

### Overrides

One argument, one tree of `<package>.<field>….<verb>`:

```nix
import ./. {
  overrides = {
    zlib.autotools.flags.append = [ "--zprefix" ];
    git.dependencies.remove = [ "pcre2" ];        # strings name packages of the final set
    curl.env.merge = { CURL_DEBUG = "1"; };
    jq.pin.merge = { version = "1.8.3"; };        # re-reads sources.toml under this pin
    jq.hash.merge = { default = "sha256-…"; };
    gcc.edit = spec: spec // { … };               # when set/append/prepend/merge/remove are not enough
  };
  packages.openssl-mine = ./openssl-mine;         # out-of-tree package, may replace an in-tree name
}
```

A list of trees is merged first, so ten layers cost what one does. Every path is checked
(unknown package or field, `append` on a non-list, a dependency naming nothing) and the result is
validated like a written spec. There is no `.override`, overlay or module system besides this.
In-tree variants use the same verbs: `llvm22` is `variant pkgs.llvm { }` with its own
`sources.toml`.

## Sources and lock files

`sources.toml` → a fixed-output fetch named after the URL, so a bumped version with a stale hash
is an error, not the old tarball. Archives are unpacked once into the store.

- **Upstream lock files are never copied or hashed.** `fetch.cargoVendor { source }` is a
  dynamic derivation: at build time a producer reads `Cargo.lock` from the fetched source and
  emits one `builtin:fetchurl` per crate with the hash the lock already has. Eval never sees it.
  npm, pnpm, Yarn, Bundler, uv, Bun, Deno likewise. The producer talks the Nix worker protocol
  (in jig), so no `nix` in the sandbox and no recursive Nix.
- **Hashes a lock file lacks** (Go, Hackage, LuaRocks) live in one sorted `locks/<eco>.toml`,
  `merge=union`, filled by `uptrack lock`. A package's vendor derivation mentions only its subset.
- **Native libraries behind locked deps** are matched at build time from a fixed menu
  (`sysLibs`, `builder/sys-libs.nu`) and become real inputs. ripgrep never lists pcre2.
- **Autoconf** probe results that are platform facts are pinned in `nix/config.site`.

## Relocatable outputs

An output refers to other store objects only relative to itself:
`$ORIGIN/../../<hash>-dep/lib`. The hash is still in the string, so GC, `nix copy` and the
reference scanner work unchanged.

| reference | made relative by |
|---|---|
| ELF NEEDED / RUNPATH | jig links with RUNPATH for exactly the dirs that satisfied a `-l`. `reloc-fixup` rewrites in place: NEEDED becomes `$ORIGIN/…/libfoo.so.1` (one `open` per library), RUNPATH keeps libc and `dlopen` dirs |
| PT_INTERP | a 300-byte entry stub (`crt-interp`) maps ld.so relative to `/proc/self/exe`. glibc unmodified, 0.09 ms |
| upstream binaries | `prebuilt = true`: formatelf implants the same stub and RUNPATH |
| scripts, wrappers | `launch`: `bin/foo` hardlink + `bin/.foo.launch` record with `{root}` placeholders. No shebang patching, no makeWrapper |
| glibc data, pkg-config, cmake | relative to `libc.so.6` (one patch), `${pcfiledir}`, native. `.la` deleted |
| exported environment | `exports.json` values with `{root}` |
| compiled-in prefix | dirname-relative patch (openssl providers). fixup warns on any absolute self-reference, `tests.relocated` runs the output from a copy |

Ambient data (CA bundle, zoneinfo, fonts) is an environment variable or system path, never a
store path. Debug info is always built and split with a relative debuglink.

## Builders

One nu process per build: `prepare` (env, unpack, patch), the package's phases, `finish`
(checks, debug split, launchers, fixup, version test, `exports.json`). Build systems are nu
modules exporting `setup configure build test install`. A package names them:

```nix
uses = [ "cmake" ];                                   # phases default to the build system's
cmake.defs = { WITH_FOO = true; };                    # typed options, checked at eval
phases = [ "cmake.configure" { name = "x"; run = "<nu>"; } ];   # only when the default does not fit
phases = [ "foo.gen" "cmake.build" ];                 # foo.<phase> lives in foo.nu beside package.nix
```

- **Dependencies contribute data, never behaviour.** Each output has an `exports.json`
  (include/lib/pkg-config dirs, env, propagation). `prepare` renders the closure into flags jig
  injects and search paths. Nothing a dependency ships runs in your build.
- **Two dependency lists.** `buildDependencies` (build machine, on `PATH`) and `dependencies`
  (target).
- **Cross is the build system's job**, from one platform record: `--host` + `config.site`, meson
  cross file, cmake toolchain file, `CARGO_TARGET_*`, `GOARCH`. Tests run under qemu.
- **Hardening and reproducibility are compiler defaults.** jig adds `-O2 -g`, frame pointers and
  the nixpkgs hardening set outside `CFLAGS`, so no Makefile drops them. `nix/hardening.nix`
  is the table, a platform or package turns names off (`cc.hardening.fortify = false`).
  `SOURCE_DATE_EPOCH`, prefix maps and fixed seeds cover reproducibility.
- **Tests run**, in the build or as `<pkg>.tests` (`tests.separate`). Every `bin/x --version`
  must print the pinned version from an empty environment under an audit module that fails on a
  `dlopen` finding nothing.

## jig and jigd

Nix caches derivations, so one changed recipe line reruns every compiler invocation downstream.
jig is the only compiler on `PATH`. If `/nix/var/nix/jigd/socket` is mapped into the sandbox
(`extra-sandbox-paths`) it asks jigd first, otherwise it compiles. Derivations never mention the
cache, so outputs are identical either way, verifiable with CA outputs.

| cached | key |
|---|---|
| `cc -c` objects, probe links, real links (ELF) | compiler identity + normalised args + source, then the headers/libs actually read (`-MD`, lld `--dependency-file`) as a manifest. Store paths are masked to content identity, so a rebuilt-identical toolchain still hits. The package's own `$out` hash is a placeholder in keys and stored objects and put back on replay, so a dependency bump alone does not recompile `-DPREFIX="$out"` code |
| compile failures | replayed when all inputs are known (most of configure) |
| rustc crates, Go actions, Haskell units | dep-info + `--extern` identities, Go's action IDs, cabal's unit id |
| `config.cache`, cmake probe results, tool cache dirs | configure scripts + toolchain + deps + flags |

jigd (Go) holds a bitcask-style object store (append-only packs, in-memory index, whole-pack
eviction, `sendfile`), remembers store-file identities so hits do not rehash headers, and hands
out build slots so N sandboxes × `make -jN` do not oversubscribe (cc/rustc per process, go via
`-toolexec`, ghc via `jsem`). sqlite3.c 82 s → 0.08 s, fd's 200 rlibs 218 s → 1.4 s,
bit-identical. The cost is trust: a cache writer can inject code, hence per user and machine.

## Toolchain, bootstrap, cross

```
seed      static musl: nu, LLVM multicall (clang, lld, llvm-ar …), bsdtar, toybox, dash, make, python
→ stage0  musl headers → compiler-rt → musl → linux headers → libc++ → jig → cc     (build machine, PATH = seed)
→ stage1  linux headers → glibc → compiler-rt → libc++ → cc-<platform>              (per target, via stage0 cc + jig)
→ pkgs/*
```

Recipes are nu (`pkgs/*/bootstrap.nu`). musl, compiler-rt and the C++ runtimes compile from file
lists without cmake, so stage0 needs only the seed (the one vendored generated file is
compiler-rt's per-cpu builtins list). A target is five minutes. What differs per target is keyed
on object format (`platform.binfmt`: elf, macho, coff), and a libc or SDK tells compiler-rt and
cc its header dirs and driver flags through `etc/cc/` files. RISC-V needed `-mno-relax`.

Self-hosting languages: the upstream binary is `<lang>-bootstrap` (prebuilt, relocated, build
dependency only) and `<lang>` is built from source with it (Go, Rust, GHC, OpenJDK). Zig
bootstraps from the WASM blob in its source. The seed comes from `pkgs/se/seed/build.nix`, today
via nixpkgs static, eventually from this set.

## Prior art

Ekala EEPs (path = attribute, explicit build systems), Aux tidepool (exports as data, one path
for native and cross), nuenv, Zig (target as a flag), Spack/Guix/conda (relocation), wrap-buddy
and fzakaria (relocatable ELF), llm-agents.nix (declarative updater).
