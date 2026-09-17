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
forcing the derivation: prebuilts are for the platforms their `sources.toml` has tarballs for (keys `x86_64-linux`, `aarch64-macos`), a
recipe can narrow with `platforms.{cpu,os,abi,libc}` lists, `platforms.posix = true` or `platforms.cross = false`, and unsupported
dependencies propagate. Only the store paths throw (`bun: sources.toml has no 'riscv64-linux' source`), so CI filters on a boolean instead of
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

A list of trees is merged first, so ten layers cost what one does, and a later tree's `remove`
also takes back what an earlier one appended. Every path is checked (unknown package, `remove`
of a missing field, `append` on a non-list, a dependency naming nothing) and the result is
validated like a written spec. There is no `.override`, overlay or module system besides this.
In-tree variants use the same verbs: `llvm22` is `variant pkgs.llvm { }` with its own
`sources.toml`.

`features` are the other direction: choices a package offers, named by the package.

```nix
{ package, pkgs, features, on }:
package {
  name = "curl";
  features = {
    tls = { values = [ "openssl" "gnutls" "none" ]; default = "openssl"; };
    docs = { default = false; };
  };
  dependencies = on (features.tls != "none") [ pkgs.${features.tls} ];
}
```

```nix
import ./. {
  features = { docs = false; };                   # every package that declares `docs`
  overrides.curl.features = { tls = "gnutls"; };  # this one
}
```

The package reads values back, so a dependency and the configure flag that goes with it stay
together in package.nix. A feature's type is its default's type, `values` limits a string or a
list's elements. Prefer those over booleans when a choice has more than two answers. Resolution is default,
then the set-wide `features` argument, then `overrides.<pkg>.features`. A wrong type, a value
outside `values` or an undeclared name is an eval error. The resolved set is part of the
derivation and readable as `pkgs.curl.features`. Packages without `features` pay nothing.

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
- **Native libraries behind locked deps** are decided when the package is pinned: uptrack reads
  the lock files in the source it just hashed, looks the names up in `builder/sys-libs.nu`
  (openssl-sys -> openssl, mattn/go-sqlite3 -> sqlite) and writes `sys = [..]` into `[pin]`.
  package.nix adds those the set has on the platform as ordinary dependencies, so eval, `info`,
  `supported` and overrides see them, and ripgrep's package.nix still never lists pcre2. The
  build system checks the lock against `sys`, so a lock that gained a -sys crate since is an
  error naming `repkgs update`, not a vendored copy.
- **Autoconf** probe results that are platform facts are pinned in `nix/config.site`.

## Relocatable outputs

An output refers to other store objects only relative to itself:
`$ORIGIN/../../<hash>-dep/lib`. The hash is still in the string, so GC, `nix copy` and the
reference scanner work unchanged.

| reference | made relative by |
|---|---|
| ELF NEEDED / RUNPATH | jig links with RUNPATH for exactly the dirs that satisfied a `-l`. `reloc-fixup` rewrites in place: NEEDED becomes `$ORIGIN/…/libfoo.so.1` (one `open` per library), RUNPATH keeps libc and `dlopen` dirs |
| Mach-O LC_LOAD_DYLIB | dependents record each dylib's absolute install name at link time (`-headerpad_max_install_names`), `reloc-fixup` respells them and store LC_RPATHs `@loader_path/…`, re-signs ad hoc |
| PT_INTERP | a 300-byte entry stub (`crt-interp`) maps ld.so relative to `/proc/self/exe`. glibc unmodified, 0.09 ms |
| upstream binaries | `prebuilt = true`: formatelf implants the same stub and RUNPATH |
| scripts, wrappers | `launch`: `bin/foo` hardlink + `bin/.foo.launch` record with `{root}` placeholders. No shebang patching, no makeWrapper |
| glibc data, pkg-config, cmake | relative to `libc.so.6` (one patch), `${pcfiledir}`, native. `.la` deleted |
| exported environment | `exports.json` values with `{root}` |
| compiled-in prefix | built under a scratch prefix that finish moves, leftovers are an error; reloc.h patch (openssl providers) |

The build never sees its store path: `$out` is `$NIX_BUILD_TOP/prefix`, finish makes what it
knows relative to the final location, fails if any file still names the prefix, and moves the
tree into the store last. An output's bytes cannot depend on where it lands, which also keeps
content-addressed rebuilds stable (lld hashes `$out` into build ids and string order;
[NixOS/nix#16465](https://github.com/NixOS/nix/pull/16465) covers derivations that do see
`$out`, and [#16477](https://github.com/NixOS/nix/pull/16477) lets a rebuild that still differs
replace the build trace of a collected output instead of failing).

Ambient data (CA bundle, zoneinfo, fonts) is an environment variable or system path, never a
store path.

Debug info is built for every package and split into a second output, `debug`, filed by
build-id (`lib/debug/.build-id/ab/cd….debug`) where gdb, lldb, perf, valgrind and
systemd-coredump look. `out` keeps `.symtab`, so backtraces and profiles have names without
it. `out` never references `debug` and `debug` is found by id, not path, so the split costs
relocatability nothing. `debug = false` is for builds that cannot be taught to keep DWARF.
An ELF package whose build produced none is an error. Sources are not shipped: DWARF names `/build/source/…`, and `pkg.src` is that tree.

Because no output names itself, every derivation (bootstrap stages included) is floating
content-addressed: a change to jig, a builder script or the toolchain that leaves a package's
bytes alone resolves its dependents to what is already in the store instead of rebuilding them.
Cross builds pass `--deny <build dep>` to reloc-fixup, so a build-machine path in a target
output is an error, not a silent reference.

## Builders

One nu process per build: `prepare` (env, unpack, patch), the package's phases, `finish`
(checks, debug split, launchers, fixup, version test, `exports.json`). Build systems are nu
modules exporting `setup configure build test install`. A package names them:

```nix
uses = [ "cmake" ];                                   # phases default to the build system's
cmake.defs = { WITH_FOO = true; };                    # typed options, checked at eval
phases.after."cmake.install" = [ { name = "x"; run = "<nu>"; } ]; # edits, or the whole list
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
  the nixpkgs hardening set outside `CFLAGS`, so no Makefile drops them. `builder/hardening.nu`
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
→ stage0  musl headers → compiler-rt → musl → linux headers → libc++ → jig → cc     (build machine, seed clang)
→ stage1  the same chain with glibc → cc-boot → cmake → llvm: clang, lld, libLLVM.so  (build machine, seed clang)
→ stage2  linux headers → glibc → compiler-rt → libc++ → cc-<platform>              (per target, stage1's clang)
→ pkgs/*
```

The seed's clang compiles stage0 and stage1 and nothing that reaches a package: stage1 exists to
give our own clang (pkgs/ll/llvm/toolchain.nu, all targets, dynamically linked so plugins can load)
a glibc and libc++ to link against, and every target's runtime is then built by it. cmake, by its
`./bootstrap`, is the one tool LLVM's build needs beyond the seed. Recipes are nu
(`pkgs/*/bootstrap.nu`). musl, compiler-rt and the C++ runtimes compile from file lists without
cmake (the one vendored generated file is compiler-rt's per-cpu builtins list). A target is five
minutes, stage1's llvm thirty once. What differs per target is keyed
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
