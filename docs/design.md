# Design

This document describes Why the set is built the way it is: what it does differently from nixpkgs, which problem each
choice addresses, and the drawbacks we accepted.
Things not built yet are in `plan.md`.

Contents: [Goals](#goals) · [Evaluation](#evaluation) · [Sources and lock files](#sources-and-lock-files)
· [Relocatable outputs](#relocatable-outputs) · [Builders](#builders) · [jig and jigd](#jig-and-jigd-compile-cache-and-build-slots)
· [Toolchain and bootstrap](#toolchain-bootstrap-cross) · [Updates](#updates)

Some in-tree programs are referred to by name below.

- **jig** is the compiler driver: the binary that is `cc`, `c++` and `rustc` on the build `PATH`, adds our flags, asks the compile cache, and as
`reloc-fixup` post-processes ELF files.
- **jigd** is its host side: one daemon per machine holding the compile cache and handing out build slots.
- **launch** is the one wrapper binary behind every installed script.
- **uptrack** updates versions and lock tables. Each has its section below.

## Goals

In priority order, with the number that says whether we got there:

1. **Cheap evaluation.** ≤ 0.2 ms and ≤ 10 KB per package. nixpkgs is about 2.6 ms and 135 KB
   per derivation, which is why `nix search` needs a cache and CI evaluations take minutes.
2. **Relocatable outputs.** No output contains its own store path, and dependencies are found
   relative to the output. This is what makes content-addressed outputs and early cut-off work
   by default instead of as a special mode, and it lets a closure run from any directory.
3. **Nushell as the build language.** Structured data instead of word splitting, real error
   handling, and a binary seed that is a handful of static executables rather than a bootstrap
   tarball of a whole userland.
4. **One toolchain.** A single LLVM targets every platform. Cross compilation is an argument to
   the set, not a parallel universe of wrapped compilers.
5. **A compile cache under Nix.** Working on the set (editing a recipe, bumping a dependency)
   should recompile what changed, not everything downstream.

The constraints we hold ourselves to: stock Nix (with `ca-derivations` and `dynamic-derivations`),
the normal daemon and `/nix/store`, no import-from-derivation, nothing fetched at eval time.
glibc is the libc. musl appears only in the static seed and stage0.

Build machines for now are x86_64-linux and aarch64-linux.
Further targets (riscv64, loongarch64, ppc64le, mingw) are cross only.

The CPU baseline is part of the platform definition (x86-64-v3, armv8.2-a+lse, rv64gc) and
injected by the compiler driver, so no package carries `-march` flags.

nixpkgs is used for dev tools (`shell.nix`, treefmt) and to build the seed, nowhere else.

Not goals: NixOS modules, nixpkgs API compatibility, a hex0-style full-source bootstrap, GCC as the system compiler.

## Evaluation

In nixpkgs a package is a function wrapped in `callPackage`, `makeOverridable`,
`mkDerivation` and its `stdenv` fixpoint, often a module evaluation on top. Each layer allocates.
We measured the extremes: 5000 packages as plain attrsets evaluate in 0.44 s and
38 MB, the same 5000 through `evalModules` take 5.8 s and 1.4 GB.

Here a package is a plain function returning a small attrset (the *spec*), and
`package` turns a spec into exactly one derivation. There is no module system and no per-package
fixpoint. Downstream edits go through one override tree (below).

```
pkgs/zl/zlib/package.nix     attribute name = directory name, sharded by two letters
pkgs/zl/zlib/sources.toml    the upstream pin, read with fromTOML
pkgs/cp/cpython314/          a second major version is simply a second package
                             (pkgs/aliases.toml maps cpython → cpython314)
```

`default.nix { platform }` lists `pkgs/*/*` with `readDir` and calls each `package.nix` with the
arguments it names (`package variant pkgs buildPkgs platform fetch sources toolchain`). Everything is
lazy, so `nix-build -A jq` imports one package file. `buildPkgs` is the set for the build machine
(the same set when not cross compiling). There are no nested package sets. Another platform is
`import ./. { platform = … }`.

`nix/package.nix` validates the spec (unknown field or option, option of the wrong type →
evaluation error, not a silently ignored attribute) and emits a derivation whose builder is `nu -c "<script>"`. Everything that
does not depend on other derivations (options, steps, env) travels as one JSON attribute, and each
dependency appears exactly once as a path, which is also the shape `derivationStrict` is
cheapest on: 1000 packages in 0.36 s and 10 MB, native or cross.

### Overrides

A user of the set changes packages without editing files through one argument:

```nix
import ./. {
  overrides = {
    zlib.autotools.flags.append = [ "--zprefix" ];
    git.dependencies.remove = [ "pcre2" ];
    git.dependencies.append = [ "libressl" ];      # a string names a package of the final set
    curl.env.merge = { CURL_DEBUG = "1"; };
    jq.pin.merge = { version = "1.8.3"; tag = "jq-1.8.3"; };   # re-reads sources.toml under this pin
    jq.hash.merge = { default = "sha256-…"; };
    ffmpeg.steps.set = [ "autotools.build" "autotools.install" ];
    gcc.edit = spec: spec // { … };               # a function, when the verbs are not enough
  };
}
```

The tree is `<package>.<field>….<verb>` with verbs `set`, `append`, `prepend`, `merge`,
`remove`, plus `edit` on a package for a spec → spec function. `overrides` may also be a list of such trees. They are
merged into one tree first, so ten layers cost the same as one: O(packages touched + edits).
exp. eval-cost measured 54 MB for 10k edits this way against 250–580 MB for `//` overlays,
`makeOverridable`, per-package `extend` or modules, which all pay per layer.

Every path is checked: an unknown package, a field that does not exist (without `set`),
`append` on something that is not a list, a dependency string naming no package, all fail with
the path in the message. The edited spec then goes through the same validation as a written one.
There is no `.override`, `.overrideAttrs`, overlay or module mechanism besides this.

Inside the tree the same verbs make a variant of another package under its own name and
`sources.toml`, e.g. `pkgs/ll/llvm22/package.nix` is `{ variant, pkgs }: variant pkgs.llvm { }`
and zig-llvm is `variant pkgs.llvm { cmake.defs.merge = { … }; steps.set = [ … ]; }`.

## Sources and lock files

`sources.toml` holds a URL template, a hash and the pinned version. `nix/sources.nix` turns it
into a fixed-output fetch named after the URL's basename, so bumping the version while forgetting
the hash is an error instead of silently reusing the old tarball. Archives are unpacked once into
the store by the seed's nu and bsdtar, and builds copy from there.

Lock-file ecosystems are where nixpkgs repositories grow without bound (vendored `Cargo.lock`
copies, `npmDepsHash` that breaks on every bump). Our rules:

- **Never copy an upstream lock file into the repo, never invent a hash for it.**
  `fetch.cargoVendor { source }` is a *dynamic derivation*: at build time a small producer reads
  `Cargo.lock` out of the already-fetched source and writes one `builtin:fetchurl` derivation per
  crate, using the sha256 the lock file already contains, plus one derivation that lays them out
  as a vendor directory. Nix then builds those. Evaluation never sees the lock file, so a
  3000-line lock costs nothing. npm, pnpm, Yarn, Bundler, uv, Bun and Deno work the same way,
  and every build system receives the result as its `deps` option, defaulted from the source. The
  producer talks to the Nix daemon through a small worker-protocol client (in jig), so this needs
  neither a `nix` binary in the sandbox nor recursive Nix.
- **Hashes a lock file lacks live in one shared table per ecosystem.** Go's `go.sum` hashes a
  file listing rather than the zip Nix downloads, Hackage and LuaRocks have no lock files at all.
  For these, `locks/go.toml`, `locks/hackage.toml` and `locks/luarocks.toml` map a version to its
  sha256, one sorted line each,
  `merge=union` in `.gitattributes` so parallel additions never conflict. `uptrack lock <pkg>`
  fills them in. Only the producer reads the whole table. Its output mentions just the package's
  own subset, so adding entries for one package does not rebuild another.
- **Native libraries behind locked dependencies are picked at build time too.** Whether some
  crate three levels down is `openssl-sys` cannot be known at eval time without IFD. So the set
  hands the producer a fixed menu of library derivations (`sysLibs` in `default.nix`), the
  producer matches lock entries against a per-ecosystem table (`builder/sys-libs.nu`), and the
  ones needed become real inputs of the vendor derivation, propagated to the package through
  `exports.json`. A package never lists pcre2 because ripgrep's regex crate wants it.

Autoconf gets the same treatment for a different reason: `nix/config.site` pins the probe
results that are facts of our platforms (the ones gnulib guesses pessimistically when cross
compiling), while package-specific probe results go through the compile cache, not into git.

## Relocatable outputs

A nixpkgs output has its own absolute store path compiled into RUNPATHs, script
shebangs, wrapper scripts and config files. That is why content-addressed derivations need a
rewriting pass, why you cannot run a closure from `~/Downloads`, and why every prebuilt binary
needs `patchelf` and `autoPatchelfHook`.

The rule here: an output refers to other store objects only relative to itself. The store is flat,
so from a file at depth *d* inside an output, a dependency is `$ORIGIN/` + `../` × (d+1) +
`<hash>-<name>/lib`. The dependency's hash still appears literally in that string, so Nix's
reference scanner, garbage collection and `nix copy` work unchanged.

How each kind of reference is made relative:

| reference | how |
|---|---|
| **ELF NEEDED and RUNPATH** | The compiler driver (jig, as `cc`) emits absolute RUNPATH entries for exactly the directories that satisfied a `-l` (plus libc and the C++ runtime) and padding. After install, `reloc-fixup` rewrites those bytes in place: each NEEDED becomes `$ORIGIN/../../<hash>-foo/lib/libfoo.so.1` (glibc expands `$ORIGIN` there and opens a name with a slash directly, so loading is one `open` per library instead of a search over every RUNPATH dir), and RUNPATH keeps only libc's dir and dirs nothing was NEEDED from, for `dlopen`. No patchelf, no section growth. |
| **The dynamic loader** (PT_INTERP) | The kernel resolves PT_INTERP before any of our code runs, so it cannot be relative. Every executable is linked with a 300-byte stub (`crt-interp`). Fixup turns the PT_INTERP header off and points the entry at the stub, which at startup maps ld.so from a path relative to `/proc/self/exe` and jumps into it. glibc is unmodified, `ldd` still works, cost is 0.09 ms per exec. |
| **Upstream binaries** | `prebuilt = true`: formatelf implants that same stub and a RUNPATH into the foreign ELF, after which fixup treats it like one of ours. (`prebuilt = "ldso"` instead wraps it in an `ld.so --library-path` launcher, used only where formatelf itself is not built yet.) |
| **Scripts and wrappers** | One 40 KB static binary, `launch`. `bin/foo` is a hardlink to it, `bin/.foo.launch` is a small record (interpreter, args, env, with `{root}` placeholders), `bin/.foo` is the real script. This replaces both shebang patching and `makeWrapper`. |
| **glibc's own data** | gconv modules and locales are found relative to the loaded `libc.so.6` (one small patch). There is no `ld.so.cache`. |
| **pkg-config, CMake configs** | `${pcfiledir}`-relative, which both support natively. `.la` files are deleted. |
| **Environment a dependency exports** | `exports.json` values may contain `{root}`, expanded by the consumer (this is how cacert sets `SSL_CERT_FILE`). |
| **A prefix compiled into the binary** | the few packages that do this get a dirname-relative patch (openssl's provider path). The rest is caught mechanically: fixup warns on any absolute store reference, and `tests.relocated` copies the output elsewhere and runs `bin/x --version` from there. |

Ambient data (CA bundle, timezones, locales, fonts) is never a store path: environment variable
first, conventional system path second. Debug info is always built (`-g`) and split into
`lib/debug` with a relative debuglink.

## Builders

nixpkgs' `setup.sh` is 1500 lines of bash that every build sources, extended by setup
hooks that dependencies inject into your build implicitly. Phases are strings, evaluated. Whether
`cmake` runs depends on whether something put it in `nativeBuildInputs`. We ran a blind test of
five builder API shapes against people and LLMs writing packages. Explicit
build systems with a plain step list won every round.

Here one nu process per build runs three things: `prepare` (environment, unpack,
patch), the package's steps, and `finish` (output checks, debug split, launchers, relocation
fixup, version test, `exports.json`, cache summary). Build systems are nu modules in `builder/`
exporting `setup configure build test install`. `setup` exports the environment and leaves the
process in the build system's working directory, so the verbs after it just run. A package
names them:

```nix
uses = [ "cmake" ];                         # steps default to cmake's configure/build/test/install
cmake.defs = { WITH_FOO = true; };          # options are per build system and checked at eval time
steps = [ "cmake.configure" … { name = "x"; run = "<nu>"; } ];   # only when the default does not fit
modules.foo = ./build.nu;                   # longer steps in a nu module of its own, "foo.<verb>"
```

The resulting rules:

- **Dependencies contribute data, never behaviour.** Each output carries an `exports.json`
  (include dirs, lib dirs, pkg-config dirs, env, what it propagates), derived from the tree by
  default. `prepare` renders the dependency closure into `CPPFLAGS`, `LDFLAGS`, `PKG_CONFIG_PATH`,
  `CMAKE_PREFIX_PATH`. Nothing a dependency ships can run code in your build. `exports = false`
  marks toolchains and applications whose `lib/` is nobody's link input.
- **`buildDependencies` and `dependencies`, not nixpkgs' six lists.** `buildDependencies` run on the build machine and go on
  `PATH`. `dependencies` are for the target: what they export says how they are consumed
  (headers and libraries for the compiler, a `bin/` or env for the installed program's launcher).
- **Cross compilation is the build system's job, done once.** autotools gets `--host` and
  `config.site`, meson a generated cross file, cmake a toolchain file, cargo `CARGO_TARGET_*`,
  go `GOARCH`, all from the same platform record. Tests run under qemu where the build system
  has a hook for it, and are reported as "untested" otherwise.
- **Hardening and reproducibility are defaults of the compiler driver, not flags packages
  remember to set.** `-O2 -g`, frame pointers, `_FORTIFY_SOURCE=3`, stack protector, stack clash
  protection, zero-initialised locals, CET/BTI, full RELRO, `--as-needed`. `-march` comes from
  the platform. `SOURCE_DATE_EPOCH` (clang derives `__DATE__` from it), `-ffile-prefix-map` for
  the build directory and every dependency, fixed hash seeds for Python and Perl, deterministic
  archives, uncompressed man pages.
- **Tests run**, in the build by default. `tests.separate` moves them to a second derivation
  that restores the build tree, so a flaky test cannot change the package's hash. `tests.skip`
  (name patterns) and `tests.parallel = false` mean the same to ctest, meson, cargo, go and make.
  `tests.version` checks that `bin/x --version` (or the command line given, `"go version"`)
  prints the pinned version, which catches many broken installs (missing data files, wrong
  rpath, stale version string).

## jig and jigd: compile cache and build slots

Nix caches derivations. Change one line of a recipe, or rebuild a dependency to
an identical result under a new hash, and every compiler invocation downstream runs again. ccache
does not help inside a sandbox that sees a fresh store path for the same header every time.

`jig` (`pkgs/ji/jig`, static C++) is the only compiler on `PATH`. It dispatches
on its name: as `cc`/`c++` it is the driver (adds `--target`, `--sysroot`, lld, compiler-rt,
libc++, platform flags, prefix maps, the RUNPATH policy, the interp stub) and the cache client.
As `rustc` it is a `RUSTC_WRAPPER`, as `gocacheprog` it speaks Go's cache protocol. It also
does `reloc-fixup` and is the Nix worker-protocol client for dynamic derivations.

If `/nix/var/nix/jigd/socket` exists in the sandbox (the user maps the host daemon's socket
in with `extra-sandbox-paths`, `tools/build` does that), jig asks it before compiling. If not, it just compiles. Derivations never
mention the cache, so outputs are identical either way, and with content-addressed outputs that
is verifiable by rebuilding without the socket.

What is cached and what the key is:

| cached | key |
|---|---|
| `cc -c x.c` → object | compiler identity + normalised arguments + source bytes, then the headers it actually read (learned from `-MD` on the first miss and stored as a manifest). Store paths in arguments and header names are masked to their content identity, so an identical toolchain under a new hash still hits. |
| `cc x.c -o x` (configure probes), `cc *.o -o x` (links) | the same over object identities. lld's `--dependency-file` supplies the libraries and linker scripts read. |
| compile *failures* | replayed too, when all inputs are known. Most of a configure run is failing probes. |
| rustc crates | arguments + dep-info inputs + `--extern` rlib identities |
| Go build actions | Go's own action IDs |
| Haskell | cabal's unit id, which already hashes source, flags and dependencies |
| autoconf `config.cache`, cmake's probe results | hash of the configure scripts + toolchain and dependency identities + platform + flags |

jigd (`pkgs/ji/jigd`, Go) serves every build on the machine:

- **Object cache.** A bitcask-style store: append-only 256 MiB pack files, an in-memory index,
  hint files for fast startup, whole-pack eviction past a size limit, values served with
  `sendfile`. Clients compress with zstd-1 (3× on objects).
- **Store-file identities.** It remembers the content hash of every store file it was asked
  about, so a cache hit does not re-hash a hundred headers.
- **Build slots.** 384 sandboxes each running `make -j384` would oversubscribe the machine, so a
  compiler starts only when jigd grants a slot. cc and rustc take one per run, go via
  `-toolexec jig slot`, and GHC through `jsem`, which serves ghc's `-jsem` semaphore from slots.

Numbers: sqlite3.c 82 s → 0.08 s, fd's 200 rlibs 218 s → 1.4 s, outputs
bit-identical. A full stage1 toolchain rebuild after touching its recipe: 5 min → 2.5 min, all of
the remainder being glibc's non-compiler work.

The drawback is trust: whoever can write to the cache can inject object code. It is a
per-user, per-machine daemon for that reason. CA outputs make tampering detectable, not
impossible.

## Toolchain, bootstrap, cross

```
seed          static musl binaries: nu, the LLVM multicall binary (clang, lld, llvm-ar …),
              bsdtar, toybox, dash, make, gawk/sed/grep/m4/bison, a minimal python
  → stage0    musl headers → compiler-rt → musl → linux headers → libc++ → jig → cc     ~3 min
              a C/C++ compiler for the build machine, PATH is only the seed
  → stage1    linux headers → glibc → compiler-rt → libc++ → cc-<platform>              ~5 min
              once per target platform, built by stage0's cc through jig
  → pkgs/*
```

The recipes are nu (`pkgs/*/bootstrap.nu`). musl, compiler-rt and the C++ runtimes are compiled
straight from file lists without cmake, which is what lets stage0 need nothing but the seed.
glibc and the kernel headers use their own build systems under the seed's dash and make. The one
generated file we vendor is compiler-rt's per-CPU list of builtins sources.

There is one LLVM per build machine. A *target* is kernel headers + glibc + compiler-rt + libc++,
about five minutes. Cross compiling is the same code path with `buildPkgs` pointing at the native
set. RISC-V needed `-mno-relax` (lld's relaxation and IRELATIVE relocations disagree). That was
the only per-target surprise.

Languages with self-hosting compilers follow one pattern: the upstream binary release is packaged
as `<lang>-bootstrap` (`prebuilt`, relocated like everything else, a build dependency only), and
`<lang>` is built from source with it. Go, Rust (against our libLLVM), GHC and OpenJDK work this
way. Zig needs no binary at all: its source ships a WASM blob of the compiler that a small C
program interprets to build stage 1.

The seed is built by `pkgs/se/seed/build.nix`, today from nixpkgs' static packages, eventually
from this set's own (plan.md).

## Updates

`uptrack` polls upstreams by package URL (`pkg:github/…`, `pkg:pypi/…`, `pkg:hackage/…`) in one
batched, cached pass, and `sources.toml` is the only file it writes, plus `locks/*.toml` for
`uptrack lock`. A package may add an `update.nu` hook for generated inputs. See `docs/uptrack.md`.

## Prior art

Ekala's EEPs (path = attribute, explicit build systems), Aux tidepool
(exports as data, one code path for native and cross), nuenv, Zig (target as a flag), Spack,
Guix and conda (relocation), wrap-buddy and fzakaria's posts (relocatable binaries, DT_NEEDED
hardening), llm-agents.nix (declarative updater).
