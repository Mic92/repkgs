# PLAN: package set with cheap eval, relocatable outputs, nushell builders

Decisions and the measurements behind them. Research checkouts live next to
this file. Benchmarks in `experiments/` (`eval-cost`, `lib-bench`, `proto`).

## 0. Scope

Goals, in priority order:

1. Cheap evaluation. Measured target: ≤0.2 ms and ≤10 KB per package
   marginal (nixpkgs: ≈2.6 ms / 135 KB per drv).
2. Relocatable outputs: no output contains its own store path. Dependencies
   are referenced relative to the output. This makes floating
   content-addressed outputs and early cut-off the default.
3. nushell as the builder language. The binary seed is a handful of static
   executables, not a bootstrap-tools tarball.
4. One LLVM toolchain for all targets. Cross compilation is an argument to
   the package set, not a splicing mechanism.

Constraints:

- Stock Nix (CppNix, Lix), no custom builtins. Normal `/nix/store` through
  nix-daemon. The `ca-derivations` feature may be required.
- glibc is the default libc. musl only for the static seed and as a variant.
- Build platforms (native, have CI builders, binary cache): x86_64-linux,
  aarch64-linux. Cross-only platforms (built from those two, never built
  on): riscv64-linux, wasm32-wasi, wasm32-unknown, arm-none-eabi,
  riscv{32,64}-none-elf.
- CPU baseline is part of `platform`: x86_64 defaults to **x86-64-v3**
  (Haswell 2013+/Zen1+: AVX2, BMI2, FMA, MOVBE; `-march=x86-64-v3`), aarch64
  to **armv8.2-a+lse** (atomics without LL/SC loops; every server core
  since 2017, Apple M1, RPi 5 — excludes RPi ≤4 and Cortex-A53/A72
  boards, which are `platform = "aarch64-linux-v8"`), riscv64 to
  `rv64gc_zba_zbb`. The level is a platform field (`platform.cpu.level`),
  so `load ./packages { platform = "x86_64-linux-v2"; }` gives a whole
  consistent set for old machines instead of per-package `-march` hacks;
  glibc hwcaps subdirectories are not used (one baseline per set, no fat
  outputs). The cc wrapper injects `-march`. Packages with runtime
  dispatch (openssl, zstd, libjpeg-turbo, glibc string ops) keep theirs.
- Core set ≈ 1k packages: toolchains, interpreters, build tools, their deps.
- nixpkgs is used only to make experiments cheap. The final tree does not
  import it.

Out of scope: NixOS modules, nixpkgs API compatibility, hex0/mes bootstrap,
GCC as system compiler, darwin, an OS layer.

## 1. Evaluation model

### Packages are functions returning plain attrsets

(exp. eval-cost), 5000 packages × 30 attributes:

| style | time | alloc |
|---|--:|--:|
| plain attrset + fixpoint | 0.44 s | 38 MB |
| + korora struct check | 0.71 s | 72 MB |
| nixpkgs `callPackage` + `makeOverridable` | +8 % | +40 % |
| `lib.evalModules` per package (Aux tidepool, drv-parts) | 5.8 s | 1439 MB |

No module system for packages. The cost grows with option count.

### Package file and tree

```
pkgs/zl/zlib/package.nix        # attribute name == directory name, sharded by the first two letters
pkgs/zl/zlib/sources.toml       # upstream pin, read at eval time (docs/uptrack.md)
pkgs/cp/cpython313/            # a second language line is a second package, not a variant
```

```nix
{ package, pkgs, platform }:
package {
  name = "zlib";
  # version and source default from ./sources.toml
  uses = [ "cmake" ];
  dependencies = [ ];
  cmake.defs = { ZLIB_BUILD_EXAMPLES = false; };
}
```

- `default.nix` walks `pkgs/*/*` with `readDir` (nixpkgs' 20k by-name dirs: 0.15 s) and calls
  each file with the scope names it asks for. Values are lazy, so `-A jq` imports one file.
  Sharding exists for git and web UIs at 20k directories, not for eval.
- `package : spec -> derivation` is the only caller of `derivation`. Always structured attrs.
- `tests` are separate derivations when `tests.separate`, never forced by `outPath`.
- Banned in the tree: `with`, `rec`, `functionArgs` tricks beyond the scope call, IFD.

### Language versions and sub-sets

There are no nested package sets. What nixpkgs uses them for:

- Library universes (pythonPackages, nodePackages): replaced by lock-driven `fetch.*Deps` per
  application (§1 Sources). Nothing to name, so nothing multiplies per interpreter version.
- Several lines of an interpreter or compiler: each line is a package, `cpython313`,
  `cpython314`, `nodejs22`, with its own `sources.toml` (`allow = "==3.13.*"`) so updates track
  patch releases per line. Shared build logic is a plain `import ../cpython314/common.nix`.
  `pkgs/aliases.toml` (`cpython = "cpython314"`) gives the unversioned name, `default.nix` merges it in and refuses aliases that shadow a directory. Consumers name a line
  explicitly or take the alias. Retiring a line deletes a directory. Expected: 2–3 lines for
  python/node/jdk/ruby/php, one for go and rust, one LLVM as *the* toolchain plus at most one
  older `llvmNN` as a library for things that link libLLVM.
- Other platform or libc (pkgsCross, pkgsStatic, pkgsMusl): an argument to the set,
  `import ./. { platform = "riscv64-linux"; }`, later `libc`/`static` the same way.
- Desktop scopes (gnome, kde): name prefixes in the flat set.

### Checks

`package` validates only the fields it consumes (`name`, `version`,
`source`, `outputs`, `buildDependencies`, `dependencies`, `exports`, `uses`, `steps`, `flags`,
`env`, booleans). Fast path: a flat table of `builtins.is*` predicates. On
failure korora's struct type renders the message
(`in struct 'spec': in member 'strip': Expected type 'bool' …`). Measured
overhead: +0.06 s / +2 MB per 1000 packages (korora alone: +0.14 s / +11 MB).
`checkTypes = false` turns it off.

Not on the `outPath` path at all: license allow/deny lists, unfree/insecure
predicates, `supports`/`broken` assertions, maintainer or description
validation. `supports` and `broken` are data read by CI and by
`lib.check.buildable`. Meta linting is one CI pass (`lib.check.meta packages`);
closure policy is an explicit query (`lib.check.closure`).

### Overrides

One mechanism: a declarative tree with five verbs, merged first, applied in
one pass while building `specs`.

```nix
import core {
  platform = "aarch64-linux";
  overrides = {
    zlib.flags.configure.append = [ "--zprefix" ];
    git.dependencies.openssl.set = "libressl";        # string = attribute path in the final package set
    git.dependencies.pcre2.remove = true;
    curl.env.merge = { CURL_DEBUG = "1"; };
    openssl.version.set = "3.3.2";
    python.packages.requests.patches.append = [ ./fix.patch ];
    ffmpeg.steps.set = [ { name = "configure"; run = ./ffmpeg-configure.nu; } "autotools.build" "autotools.install" ];
    gcc.__fn = spec: spec // { };                  # escape hatch, receives the spec only
  };
}
```

Verbs: `set`, `append`, `prepend`, `merge`, `remove`. `overrides` may be a
list of trees. They are merged as trees (`set` last wins, list verbs
concatenate), so cost is O(packages + edits) regardless of layer count.
Every layered design measured O(layers × packages) memory
(exp. eval-cost: 54 MB vs 250–580 MB at 10k edits for `//`
overlays, `makeOverridable`, infuse, per-package `extend`, on-demand
modules). The tree is checked against the spec shape: unknown package or
field, `append` on a non-list, dangling reference → error with path.
No `prev:`/`old:` lambdas, refs are strings, typos cannot no-op, the tree
is JSON-serialisable — which is also what makes it easy for LLMs.

There is no `.override`, `.overrideAttrs`, `.extend`, overlay or module
mechanism for packages.

### Sources, lock data, updates

`package.nix` declares how to find new versions (`extra.update = {
source = "github-releases" | "url-regex" | …; versionPolicy; urlTemplate;
}`, the llm-agents.nix model); a sibling `lock.json` holds `version` and
hashes and is the only file the updater writes. `package` reads it with
`fromJSON (readFile …)`, measured indistinguishable from zero at 1000
packages (a second `.nix` file would cost 0.1 ms each). Fetching:
`builtin:fetchurl` for url/tarball sources (no seed dependency, works
before anything is built). Forge archives by URL. `git` only as an
ordinary command dependency when a tarball does not exist.

Ecosystem lock files (Cargo.lock, package-lock.json) are *not* copied into
the repo and get no hash of ours. `fetch.cargoVendor { source }` is a
dynamic derivation: a tiny producer (nu + `jig nix-store`, running with
`requiredSystemFeatures = ["builder-rpc-v0"]`) untars the lock file from
`source`, writes one `builtin:fetchurl` derivation per crate using the
sha256 the lock already records, one derivation that unpacks them into
cargo's `[source.vendored]` layout, and submits that `.drv` as its output.
Packages use `builtins.outputOf producer "out"`. Nix downloads, verifies
and dedups per crate across all packages, the eval sees one attribute.
`jig nix-store` speaks the worker protocol's `AddToStore`/`SubmitOutput`
directly (plus ATerm and store-path computation, ≈400 lines), so no `nix`
binary and no `recursive-nix` is involved. Requires the building daemon
to have `ca-derivations dynamic-derivations`. Go stays a single-hash FOD
(`go.sum` hashes module trees, not the zip files a fetchurl could check).

### Measured (exp. proto)

1000 synthetic packages shaped like C libraries (0–5 dependencies, 2 buildDependencies,
propagation, exports, platform-dependent flags, 1–2 outputs), all outPaths,
checks on: 0.36 s CPU, 10 MB. Of that: nix startup 0.09 s, parsing
0.10 s (0.1 ms per file), our code ≈0.07 s, `derivationStrict` ≈0.10 s.
Cross (`platform = "aarch64-linux"`) costs the same because `buildPackages` is
only forced for build dependencies actually used.

What the tuning (0.82 → 0.36 s) established about `derivationStrict`:
minimal drv ≈10 µs. Cost is linear in serialized leaves and in
context-carrying strings (3–6 µs each). Hence:

- context-free knobs (uses, steps, per-ecosystem knobs, env, exports) go into one
  pre-`toJSON` string attribute;
- each dependency appears exactly once, as a path (see exports in §3);
- per-set constants (platform record, toolchain description) are one
  `toFile` referenced by path;
- builder and hook references are strings into one builders store path.

CI tracks thunks and bytes per package. +5 % median needs sign-off.

## 2. Library

Written from scratch, ≈40 functions over builtin fast paths, vendored
korora for types. Namespaced by data type with nushell/JS vocabulary so
Nix and builder code share names: `lib.str`, `lib.list`, `lib.attrs`,
`lib.version`, `lib.path`, `lib.platform`, `lib.fetch`, `lib.build`,
`lib.types`, `lib.check`. One name per function, no flat re-exports.

Rules from (exp. lib-bench):

1. Set operations go through attrsets or `genericClosure`. nixpkgs `unique`
   is O(n²) (0.71 s vs 0.18 s at 20k). `foldl' (//)` allocates 10× what
   `zipAttrsWith` does.
2. Propagation closure uses `genericClosure` keyed on `outPath`.
3. `lib.platform.parse` returns a function-free record once per package set
   (20× cheaper than `systems.elaborate`, serialisable).
4. No shell-string helpers exist (`escapeShellArg`, `makeSearchPath`,
   `makeBinPath`). Data goes to nu as JSON.
5. Static nested access is `x.a.b or d`. Path helpers are internal to the
   override walker.
6. `package` guarantees `outputs.{out,bin,lib,dev,man,doc}` (aliasing
   `out`), `buildDependencies`, `dependencies`, `exports`, `meta`, `tests`, `spec` on
   every package, so there are no `getBin`/`getDev`/`optionalAttrs (x ? y)`
   accessors.
7. No nested lists in specs. No `flatten`.

### Names (nixpkgs → here)

Spec fields:

| nixpkgs | here |
|---|---|
| `stdenv.mkDerivation` | `package` |
| `pname` | `name` (store name is derived) |
| `src`, `srcs` | `source`, `sources.{main,…}` |
| `nativeBuildInputs` | `buildDependencies` |
| `buildInputs` | `dependencies` |
| `propagatedBuildInputs`, `setupHook`, `NIX_CFLAGS_COMPILE`, `NIX_LDFLAGS` | `exports = { cflags, ldflags, pkgconfig, env, propagate, hook, … }` |
| `depsBuildBuild` … `depsTargetTarget` | `buildDependencies`/`dependencies` + `buildPackages` |
| `stdenv.{build,host,target}Platform` | `platform` (runs there), `buildPlatform` (built there), as in Docker's TARGETPLATFORM/BUILDPLATFORM |
| `preConfigure`/`configurePhase`/`postConfigure` | an inline `{name; run;}` entry in `steps`. No hooks |
| `configureFlags`/`cmakeFlags`/`mesonFlags` | `autotools.flags` / `cmake.defs` / `meson.options` (only the one matching `build` is accepted) |
| setup hooks, `dontUseCmakeConfigure` | none. `uses = [ … ]` is explicit |
| `configureFlags`, `makeFlags`, `cmakeFlags` | `flags.configure`, `flags.make`, `flags.cmake` |
| `dontStrip`, `enableParallelBuilding` | `strip = false`, `parallel = false` |
| `doCheck`, `checkPhase`, `passthru.tests` | `tests.<name>` |
| `passthru` | `extra` |
| `meta.platforms`, `badPlatforms`, `broken = true` | `supports = [ "@linux" "x86_64-*" ]`, `broken = "reason"` |
| `meta.mainProgram` | `program` |
| `outputBin`, `outputLib`, … | fixed by output name |
| `callPackage ./x.nix { }` | directory walk |
| `pkgsCross.aarch64-multiplatform.foo` | `(load ./packages { platform = "aarch64-linux"; }).foo` |
| `python3Packages`, `python311Packages` | `python.packages`, `python.v3_11.packages` |
| `ffmpeg_4`, `nodejs_22` | `ffmpeg.v4`, `nodejs.v22` |
| `runCommand`, `writeText`, `writeShellScriptBin`, `symlinkJoin`, `linkFarm` | `lib.build.{run,file,script,merge,tree}` |
| `fetchurl`, `fetchzip`, `fetchFromGitHub`, `fetchgit`, `fetchPypi` | `lib.fetch.{url,tarball,github,git,pypi}` |
| `lib.getBin p`, `"${p}/bin/x"` | `p.outputs.bin`, `lib.path.exe p "x"` |

Functions:

| nixpkgs | here |
|---|---|
| `attrNames`, `attrValues`, `mapAttrs`, `mapAttrsToList`, `filterAttrs` | `attrs.{keys,values,map,mapToList,filter}` |
| `genAttrs`, `listToAttrs` | `attrs.fromKeys`, `attrs.fromPairs` |
| `recursiveUpdate`, `mergeAttrsList`, `zipAttrsWith`, `optionalAttrs` | `attrs.{mergeDeep,mergeAll,zip,when}` |
| `concatMap`, `concatLists`, `unique`, `foldl'`, `partition`, `groupBy`, `sort` | `list.{concatMap,concat,dedupe,fold,partition,groupBy,sort}` |
| `optional`, `optionals` | `list.when cond [ … ]` |
| `head`, `last`, `take`, `drop`, `elem`, `any`, `all`, `range` | `list.{first,last,take,skip,has,any,all,range}` |
| `concatStringsSep`, `splitString`, `hasPrefix`, `hasSuffix`, `removePrefix`, `removeSuffix`, `optionalString`, `toLower` | `str.{join,split,startsWith,endsWith,stripPrefix,stripSuffix,when,lower}` |
| `versionOlder`, `versionAtLeast`, `versions.major`, `splitVersion` | `version.{lt,ge,major,parts}` |
| `systems.elaborate`, `systems.parse` | `platform.parse`, `platform.matches` |
| `fix`, `extends`, `makeScope`, `makeScopeWithSplicing'` | `load { dir, buildPackages, parent }` |
| `throwIfNot`, `assertMsg`, `warn` | `check cond msg v`, `warn msg v` |
| `lib.types`, `mkOption` | `types.*` (korora) |

Dropped: `escapeShellArg(s)`, `makeSearchPath*`, `makeBinPath`,
`getBin/getLib/getDev/getOutput`, `flatten`, public `*AttrByPath`,
`naturalSort`, `toString` on lists, `stdenv.shell`, `stdenv.cc`
(→ `buildPackages.toolchain`).

## 3. Relocatable outputs

Rule: an output references other store objects only relative to itself.
The store stays flat, so from depth *d* inside an output a dependency is
`$ORIGIN` + `../`×(d+1) + `<hash>-<name>/…`.

- No self-references, so an output's CA hash is its NAR hash. No
  hash-rewriting modulo self.
- The `<hash>` still appears literally, so Nix's reference scanner, GC and
  `nix copy` work unchanged, under `/nix/store` or any other root.
- A rebuild producing identical bits does not change dependents' inputs.

| reference kind | mechanism |
|---|---|
| ELF rpath | the link step cannot know the file's install depth, and uninstalled binaries must run during the build, so the ld wrapper (§4) emits *absolute* store RUNPATH entries (only directories that satisfy a `-l`, plus libc, plus build-tree rpaths the build system asked for; `/usr`-style dirs are an error) followed by pad entries. fixup rewrites the same bytes to `$ORIGIN`-relative for the file's depth, drops non-store entries, and fails if it would not fit or an absolute path remains ((exp. ldwrap): zlib, libtool'd xz, depth-4 binary relocate and run). |
| PT_INTERP | the kernel resolves it relative to cwd, so it cannot be used at runtime. The wrapper links a normal absolute `--dynamic-linker` (with `./` slack), `crt_interp.o` (2.4 KB freestanding) and exports `__reloc_start`. During the build the file is an ordinary executable. fixup rewrites `.interp` to a path relative to the file, flips that phdr's `p_type` to `PT_NULL`, and sets `e_entry` to `__reloc_start`. At startup the stub reads `.interp`, maps ld.so relative to `/proc/self/exe`, flips the phdr back in memory, sets `AT_BASE`/`AT_ENTRY`, and jumps into ld.so with the untouched initial stack ((exp. reloc-interp)): argv/env/`/proc/self/exe` unchanged, `ldd` works, +0.09 ms per exec, glibc unmodified. Seed tools are static-pie musl. |
| glibc lookups | no `ld.so.cache`. gconv dir, locale dir/archive and `locale.alias` resolved relative to the loaded `libc.so.6` (its link-map `l_name`), env overrides kept. strace of a relocated closure shows these are the only absolute opens. NSS needs nothing since files/dns are built into libc ≥2.34 |
| upstream binaries (`prebuilt`) | not patched: launch runs them as `<sysroot>/lib/ld.so --argv0 bin/foo --library-path <libc:deps' libDirs> libexec/foo`, `libgcc-shim` supplies `libgcc_s.so.1` over libunwind. Used for rustc/cargo (docs/plan.md 5) |
| shebangs, env wrappers | one static-pie `launch` binary in its own store path. `bin/foo` is a symlink `../../<hash>-launch/bin/launch`, the record sits beside it as `bin/.foo.launch` (JSON: `program`, `args`, optional `argv0`, `env` with `{root}`/`{store}`/`{self}` templates), the original script as `bin/.foo.script`. argv[0] defaults to the program so interpreters find their prefix. Replaces `#!` lines and `makeWrapper`. fixup converts every script and every ELF that has runtimeDependencies. |
| interpreter module paths | native relative mechanisms where they exist (`pyvenv.cfg`/`._pth`, Perl `FindBin`+`use lib`, `NU_LIB_DIRS`), launcher env otherwise |
| dlopen-only libraries | `runtimeDependencies` spec field. The ld wrapper adds them as DT_NEEDED with relative RUNPATH (fzakaria's "harden needed": make the dependency visible to ld.so instead of searching at runtime), so the reference scanner and relocation both see them |
| debug info | always built with `-g`. `debug` output on every ELF-producing package: `llvm-objcopy --only-keep-debug`, relative `.gnu_debuglink`, build-id = content hash; served by debuginfod from the binary cache |
| pkg-config | `prefix=${pcfiledir}/../..` |
| cmake configs | relative by default |
| `.la` files | deleted |
| text files | `{{dep}}` placeholders resolved by the builder to relative paths for the file's depth |
| compiled-in prefix | build with `--prefix=/nonexistent/<hash>-<name>`. Fixup fails if the string survives. Packages needing runtime prefix lookup get patches (`/proc/self/exe`, `dladdr`). Escape hatch `relocatable = false` disables CA for that package. CI reports the count. |

CI scans every output for its own path and for the store root.
There is no patchelf: fixup's ELF edits are byte overwrites at existing
offsets (RUNPATH string, `.interp` string, one `p_type`, `e_entry`), never
layout changes. The wrapper guarantees the slack.

Prior art: Spack relocation, Guix `pack -RR`, conda prefix placeholder,
wrap-buddy `--relocatable`, fzakaria "Nix needs relocatable binaries" /
nix-harden-needed.

### Ambient runtime data (tzdata, CA certificates, locales)

These are not dependencies of libc/openssl — baking their store paths in
would rebuild the world on every tzdata/cacert bump and defeat CA cutoff.
Rule: **env var first, conventional system path second, nothing
store-relative compiled in.**

| data | env (honoured upstream) | compiled-in fallback | package |
|---|---|---|---|
| time zones | `TZDIR`, `TZ` | `/etc/zoneinfo` then `/usr/share/zoneinfo` | `tzdata` (`share/zoneinfo`) |
| CA bundle | `SSL_CERT_FILE`, `SSL_CERT_DIR` (+ `NIX_SSL_CERT_FILE` for compat) | `/etc/ssl/certs/ca-certificates.crt`, `/etc/ssl/certs` | `cacert` |
| locales | `LOCPATH` (upstream, split dirs; no `LOCALE_ARCHIVE` patch) | `C`, `POSIX`, **`C.UTF-8` built into libc** (glibc ≥2.35) | `locales` (all), `locales-min` (en_US + C) |
| gconv | — (found relative to `libc.so`, §3 patch) | | part of glibc |
| terminfo | `TERMINFO_DIRS` | `/etc/terminfo:/usr/share/terminfo` + ncurses' compiled-in fallback entries for xterm-256color, screen, tmux, linux, vt100 | `ncurses` (`share/terminfo`) |
| mime, XDG data | `XDG_DATA_DIRS` | — | leaf sets |

So on NixOS and on FHS distros binaries behave with zero configuration;
UTF-8 works without any locale files. For relocated/bundled closures the
*profile* carries the data, not the packages: `pkgs bundle`/`pkgs profile`
(§6) links `tzdata cacert locales-min` into the profile and writes
`etc/profile.env` (and the launcher records of programs in that profile
get `TZDIR=$PROFILE/share/zoneinfo` etc. as *defaults*, i.e. only if
unset). Data packages are thus updated by swapping a symlink, never by
rebuilding consumers. CI check: no ELF in the set contains the store path
of tzdata, cacert or locales.

## 4. Builders

nushell replaces `setup.sh` and hooks. Structured attrs arrive as JSON;
nu covers coreutils/findutils/sed/grep/diff/which/hashing/globbing, so
those leave the seed. Errors carry spans. nuenv showed the mechanics.

```
builders/
  core.nu       step runner, relpath, reference scan, rpath/shebang fixup, strip
  cc.nu         compile source lists directly (no configure)
  autotools.nu  cmake.nu  meson.nu  cargo.nu  go.nu  python.nu
```

- **No generic builder, no driver, no hooks** (chosen by blind LLM test
  over four alternatives, exp. builder-api). A package says
  `uses = [ "cargo" "npm" ]`: each named ecosystem is a *layer* that does
  its setup unconditionally before any step (vendor from its `lock.json`
  key, `node_modules` in `npm.root`, env, PATH, deps' exports rendered its
  way, `platform` rendered for cross). Nothing is detected. A dependency
  cannot switch anything on. `cc` is always a layer.
- **Steps are data**: `steps = [ "npm.build" "cargo.build" "cargo.test" "cargo.install" ]`,
  names only, no arguments. With one ecosystem the standard list is
  implied (cargo `build test install`, cmake `configure build test
  install`, …); with several, `steps` is required (eval error otherwise).
  `tests.run = false` drops `*.test`. an inline `{ name = "docs"; run = "<nu>"; }`
  entry in `steps` is a custom step. There are no
  `hooks.before/after`: in the test they were where knob values got
  hardcoded (`"npm run build"`) so that downstream `npm.script.set` silently
  did nothing. With name-only steps every value lives in a knob the
  override tree can reach, and order is a list it can edit
  (`steps.remove = [ "cargo.test" ]`).
  `uses = [ "python" "cargo" ]; python.backend = "maturin"; steps = [ "python.build" "python.test" "python.install" ];`
  `uses = [ "go" "npm" ]; npm.root = "web"; npm.script = "release"; steps = [ "npm.build" "go.build" "go.test" "go.install" ];`
  Accepted knob namespaces are exactly `uses`. Layer tool deps are
  appended to `buildDependencies` from a static table.
- Knobs are namespaced and typed per build system: `autotools.flags`,
  `cmake.defs = { WITH_FOO = true; }` (rendered `ON/OFF`), `meson.options`,
  `cargo.features`, `go.tags`, `python.backend`. The check table is per
  builder, so `cmake.defs` on an autotools package is an eval error. There
  is no `configureFlags`/`makeFlags`/`NIX_CFLAGS_COMPILE` lingua franca and
  no `dont*` negations, because nothing is implied.
- **Layers are values, user-extensible.** A layer is a record
  `{ module = ./zig.nu; knobs = { <name> = predicate; }; defaults; steps
  (implied list); buildDependencies; lockKey; updater ? null; platformFile ? null }`.
  Ours live in `buildSystems/default.nix` as a plain attrset. `load` takes a
  `buildSystems` argument merged over it and the override tree can address
  `buildSystems.<name>`, so
  adding (`zig`, `bazel`, `dune`) or replacing (`cargo` with a patched
  vendoring scheme) a layer is an attrset merge outside our tree.
  `package` resolves each `uses` entry there (unknown → eval error with
  the available names), takes knob table/defaults/implied steps/build dependencies
  from the record. `core.nu` `use`s the modules by path and checks that
  every name in `steps` is an exported verb. Layer names may not collide
  with reserved top-level fields. `lockKey`s must be unique. Cost: one
  lookup per used layer per package.
- Each layer's verbs are nu functions reading their knobs from the spec
  (`cargo build` uses `cargo.features`, `npm run` uses `npm.script`), also
  callable interactively in `pkg.devShell`. `fixup` is the only shared
  tail and is not a step anyone can replace.
- Dependencies contribute data, never behaviour: the consuming builder
  renders each dep's `exports.json` into its native form (cmake
  `CMAKE_PREFIX_PATH` + toolchain file, meson `--pkg-config-path` + cross
  file, autotools `PKG_CONFIG_PATH`/`ACLOCAL_PATH`/`config.site` + `--host`,
  cargo target config, cc `-I/-L`). Setup hooks do not exist.
- Per-platform artefacts (cmake toolchain file, meson cross file, cargo
  target config, `config.site`) are generated once per package set from
  `platform` via `toFile` and shared by all packages.
- Per-builder defaults: out-of-tree build dir, `DESTDIR` staging with a
  check that nothing wrote outside `$out`, parallel always, one `profile`
  knob mapped to `--release`/`CMAKE_BUILD_TYPE`/`-Dbuildtype`, tests as a
  separate CA derivation reusing the build tree (`tests.run`).
- Eval cost: `uses`, `steps` and the namespaced knobs are context-free members
  of the single `spec` JSON (§1). Nothing per package is added.
- Exports: a package declares `exports` as structured, context-free data
  whose paths are relative to its own root (`includeDirs`, `libDirs`,
  `libs`, `pkgconfigDirs`, `cmakeDirs`, `aclocalDirs`, `env`, `propagate`;
  defaults `["include"]`, `["lib"]` cover most packages). No flag strings
  and no self placeholder: the output never names its own store path, and
  the consumer's builder renders the data (`-I/-L/-l`, cmake prefix,
  pkg-config path) against wherever the dep is mounted. Its own builder
  writes this as `$out/exports.json`.
  Dependents' derivations contain only `dependencies = [paths]` and
  `buildDependencies = [paths]`. Their builder reads each dependency's
  `exports.json`. This is both the cheapest drv shape (§1) and the
  relocatable one. `exports.propagate` is closed over at eval time with
  `genericClosure` so propagated packages are real inputs. `pkg.exports`
  stays queryable in Nix.
- `fixup` does the §3 in-place rewrites (RUNPATH, `.interp`, entry),
  verifies (reference scan, no absolute paths, no prefix leaks), strips,
  splits debug info, drops `.la`, writes `exports.json` and relative `.pc`.
- `core.nu` creates a GNU make jobserver sized to `NIX_BUILD_CORES`;
  make, ninja, cargo and nu `par-each` take tokens from it.
- `core.nu` emits JSON-lines records (step, timing, errors) to
  `$NIX_LOG_FD`, plain text otherwise.
- Sandbox `/bin/sh` is not relied on. Builders pass `SHELL`/`CONFIG_SHELL`
  pointing at our bash when a package needs one. CI runs with empty
  `sandbox-paths`.

### cc/ld wrapper

A static C++ binary (seed clang + libc++), first package built, dispatching
on argv[0] (`cc`, `c++`, `cpp`, `ld`, `rustc-wrapper`). It is the only
compiler entry point on PATH, so every build system goes through it
unchanged. It replaces nixpkgs' bash cc-wrapper, ld-wrapper,
`patchelf --shrink-rpath`, most of fixup, and ccache/sccache:

- every path-bearing flag (`-ffile-prefix-map` for build dir, deps,
  tools, libc headers, resource dir. `--sysroot`) is injected here and
  never appears in `CFLAGS`, because packages that record their build
  flags (jq, perl, python, ruby) would turn them into references;
- adds `--target`, `-march=<platform.cpu.level>`, `--sysroot`,
  `-fuse-ld=lld`, runtime-lib selection, reproducibility flags
  (`-ffile-prefix-map`, `-frandom-seed`, build-id from content), and the
  two default flag groups below;
- **profiling-friendly by default** (whole set, not opt-in):
  `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer` (Fedora 38 /
  Ubuntu 24.04 measured <1 %. Makes `perf`, eBPF profilers, and crash
  unwinding work without DWARF), `-g` always with the DWARF split into the
  `debug` output (§3: `--only-keep-debug`, relative `.gnu_debuglink`,
  content build-id) so the main output is no larger than a stripped one and
  `debuginfod` over the binary cache serves symbols by build-id. `.symtab`
  kept in shared libraries (only `.debug_*` moves), `-Wl,--build-id`;
  glibc/libc++/compiler-rt built the same way so stacks never break inside
  the runtime. `profile = "debug"` additionally drops to `-Og`.
- **hardened by default**: `-D_FORTIFY_SOURCE=3`,
  `-fstack-protector-strong`, `-fstack-clash-protection`,
  `-ftrivial-auto-var-init=zero`, `-fPIE`/`-pie` for programs,
  `-Wl,-z,relro,-z,now,-z,noexecstack,-z,pack-relative-relocs,--as-needed`,
  `-fcf-protection=full` on x86_64 / `-mbranch-protection=standard` on
  aarch64, libc++ built with `_LIBCPP_HARDENING_MODE_FAST` (bounds checks
  in `span`/`vector[]`/`optional`), glibc `--enable-bind-now
  --enable-fortify-source`. Both groups are part of the platform's
  toolchain description, so they change derivation hashes once, globally,
  and the compile cache keys on them like any flag.
- **Compile cache covers Rust and Go too**, same socket and rules:
  `RUSTC_WRAPPER=jig` keys each crate on rustc id + args + dep-info
  inputs + `--extern` hashes (vendored dependency crates hit across
  packages. Build dir and `--remap-path-prefix` are fixed so keys are
  stable between derivations). `GOCACHEPROG=jig --gocacheprog` (Go ≥1.24
  external cache protocol) serves Go's own content-addressed action cache
  from the CAS. C/C++ compiled underneath node-gyp, Python extensions,
  `build.rs`/cc-rs and maturin goes through `cc` and is covered already.
  Final links, bytecode and JS bundling are not cached. CI samples hits in
  verify mode (rebuild, compare bytes, fail on mismatch).
- **Turning default flags off**, four scopes, one vocabulary. Every
  injected flag belongs to a named switch: `fortify stackProtector
  stackClash autoInit pie relro bindNow cfProtection framePointer debugInfo
  march lto`.
  1. *Package*: `cc.flags.fortify = false;` (typed bools under `cc.flags`,
     unknown name = eval error). Goes into `spec`, `core.nu` writes it to
     the wrapper's per-build config file. Nothing else to do.
  2. *Downstream*: the same path through the override tree,
     `overrides.openssl.cc.flags.cfProtection.set = false`.
  3. *Whole set / platform*: `load ./packages { platform = "arm-none-eabi";
     toolchain.flags = { pie = false; stackProtector = false; }; }`;
     bare-metal platforms default most of them off. This is the only place
     `march` normally changes.
  4. *Inside a build*, for one step or one sub-make where only some files
     must differ (glibc's `rtld`, a JIT, a benchmark):
     `PKGS_CC_FLAGS=-fortify,-stackProtector make -C elf` — the wrapper
     reads this env var per invocation. `+name` re-enables.
  Independent of these, the wrapper *prepends* its defaults and never
  appends, so an explicit `-fno-stack-protector`, `-U_FORTIFY_SOURCE`,
  `-fomit-frame-pointer` or `-O0` coming from the package's own build
  system wins by ordinary last-flag-wins. nixpkgs' failure mode of the
  wrapper silently re-adding a flag after the package disabled it cannot
  happen. `-Werror` builds that trip over `-D_FORTIFY_SOURCE` with `-O0`
  are handled the same way (fortify is dropped by the wrapper when it sees
  `-O0`). CI prints the list of packages with any switch off (and greps
  build logs for package-supplied negating flags), so opt-outs stay visible
  without a `hardeningDisable`-style honour system.
- reads an index that `core.nu` writes once per build from the
  dependencies' `exports.json` (include dirs, lib dirs, private libs for
  static links) — no `NIX_CFLAGS_COMPILE`/`NIX_LDFLAGS` strings. `.pc` files
  are generated for foreign consumers but not read by the wrapper;
- at link time resolves each `-l` and each `runtimeLibraries` entry to its
  directory and emits exactly those (absolute, padded) as RUNPATH. Passes
  build-tree rpaths, rejects `/usr`, `/lib*`, `/opt`. Adds the padded
  absolute `--dynamic-linker`, `crt_interp.o`,
  `--export-dynamic-symbol=__reloc_start`, `--undefined-version` (GNU ld
  compatibility for version scripts). Fixup does the relative rewrite (§3);
- response files and `@file` expansion handled before rewriting;
- caches compiles and links, always on (proven in exp. cc-cache:
  sqlite3.c 82.5 s → 0.08 s across distinct derivations, bit-identical
  objects). It probes `/run/pkgs-cache.sock`, which the nix-daemon maps
  into the sandbox via `sandbox-paths` (or `pre-build-hook`). No socket →
  plain compile, so derivations and their hashes never mention the cache.
  Key = wrapper + compiler store paths, normalised args, source bytes, and
  per included header its store path (immutable, not hashed) or content
  hash if in the build tree, header list learned from `-MD` on the first
  miss. `-ffile-prefix-map`/`-frandom-seed` are already set, so hits equal
  misses bit for bit. Same scheme for `rustc` and for link lines (key over
  input object hashes). `jig --serve` is the host side: local CAS with
  LRU bound, optional remote CAS (HTTP/S3/REAPI) so CI builders share.
  Trust: cache writers can inject code. CA outputs make it detectable by
  rebuild. CI writes the shared namespace, developers read shared / write
  local, release and reproducibility lanes run without the socket and
  must reproduce CI's CA hashes. `cache = false` per package opts out.
  Later, per-TU dynamic derivations can replace this with the store as
  object cache. The key function is chosen to become that drv's input
  hash.
- `pkg.devShell` reuses the spec: `overlay use` of the builder module with
  the package environment, steps callable interactively. The same
  wrapper and cache socket work there.

### Working on a package (dev shells)

`nix develop` captures a derivation's environment by re-running its
builder as *bash* with `get-env.sh`. Our builder is nu, so stock
`nix develop .#foo` cannot introspect the real build derivation. Two
things are offered instead, and both end in the same place:

1. `pkgs dev <name> [--at ./checkout]` (a nu script in the repo, also
   `nix run .#dev -- <name>`): evaluates the package's `spec` JSON,
   realises `inputDerivation` (all inputs, no build), then starts an
   interactive `nu` with `use core *; use <build systems>; prepare --dev`
   — exactly the prelude of the real build script (§4), except `src` is
   your checkout (or an unpacked copy under `./worktree/<name>`) and
   `out=$PWD/out`. PATH, CC, CFLAGS, PKG_CONFIG_PATH, prefix maps, the cc
   wrapper and cache socket are identical to the sandboxed build. Steps
   are the same commands: `cmake configure`, `cmake build`, `cargo test`,
   or `steps` to run the package's list. `steps --from cmake.build`
   resumes. Because build systems are modules, tab completion and
   `help cmake configure` work. This is the primary workflow and needs no
   bash anywhere.
2. `devShells.<system>.<name>` for `nix develop`/direnv users: a tiny
   derivation whose builder *is* bash (from `buildPackages`, not the
   seed) and whose env is generated at eval time from the same `spec`
   (exported variables + PATH from `buildDependencies`), with
   `shellHook = "exec nu -e 'use core *; prepare --dev'"` unless
   `PKGS_DEV_SHELL=bash`. So `use flake .#foo` in `.envrc` gives editors
   and LSPs the right PATH/CC/PKG_CONFIG_PATH, and an interactive
   `nix develop` drops into the nu environment of (1).

Editor/LSP integration comes from (2) plus `compile_commands.json`, which
the cc wrapper can emit for any build (`PKGS_CC_COMPDB=1`) regardless
of build system.

### Seed (per build platform, static, pinned by hash)

1. `nu`
2. LLVM multicall: `clang`, `lld`, `llvm-{ar,ranlib,objcopy,strip,nm,…}`, all
   targets, resource headers. compiler-rt/libc++/musl as *sources*
3. `bsdtar` (nu has no archive support)
4. `toybox` (nu has no ln/chmod/readlink; configure scripts before any
   package exists need expr/tr/sed/…. 0.5 MB)
5. `dash`, GNU `make`, `gawk sed grep m4 bison`, a minimal `python3`: what glibc's and the GNU
   userland's own build systems require. Building them in stage0 from nu file lists worked
   (dash's generators ported, toybox headers regenerated) but duplicated every one of them with
   its later `package.nix`, so they moved into the seed.

Shipped as one `seed-<n>-<platform>.nar.xz` fetched by
`<nix/fetchurl.nix>` with `unpack = true` (builtin, restores a NAR: no
tar needed to obtain tar). That is the whole seed (experiments 7, 12). stage0 builds from it, with nu + clang only: musl,
compiler-rt, linux headers, libunwind/libc++abi/libc++, then jig and the native `cc`. stage1
repeats that per platform with glibc. The only vendored generated input is compiler-rt's
per-cpu builtins list (`pkgs/ll/llvm/`, its `update.nu` reruns cmake per LLVM bump);
libc++/libunwind sources are globbed with a short documented skip list.

Bring-up builds the seed with nixpkgs `pkgsStatic`. Stage 1 rebuilds it
with itself and CI checks the fixed point.

dash runs configure scripts. Bash is a normal package for bash-specific
build scripts. build-time coreutils are uutils, plus GNU sed/grep/gawk. Libraries with simple builds
get `cc.nu` recipes instead of `./configure`: zlib, bzip2, xz, zstd, lz4,
brotli, expat, sqlite, mpdecimal, libedit. cmake/ninja/meson/cargo/go
packages never see bash. CI reports the share of the core closure that
builds without bash.

Bring-up set (experiments 5–8): cc/ld wrapper, launch, musl, glibc,
compiler-rt, libunwind, libc++, zlib, zstd, xz, bzip2, make, bash, uutils,
sed, grep, gawk, patch, pkgconf, cmake, ninja, python, curl, openssl, git.

nu churn: one pinned nu per release, `--no-config-file`, vendored std-lib,
builders restricted to a reviewed subset.

## 5. Toolchain and cross

- One LLVM per build platform. clang is invoked with
  `--target= --sysroot=<relative libc> -fuse-ld=lld -rtlib=compiler-rt
  -unwindlib=libunwind -stdlib=libc++`.
- libc is part of `platform`: glibc (linux default), musl, wasi-libc,
  none/picolibc. compiler-rt, libunwind, libc++, libc are ordinary packages
  parameterised by `platform`. glibc builds with clang ≥17 + lld. Its
  build needs gmake, bash, python, gawk, bison — the one early bash cluster.
- Dependency kinds are four names, no platform triples:
  `buildDependencies` (built for the build platform, on PATH while
  building), `dependencies` (built for `platform`, visible to the compiler,
  referenced at run time if actually linked), `runtimeDependencies` (for
  `platform`, never seen by the build: exec'd programs, dlopen'd libraries,
  plugin dirs. Land in the launcher record / DT_NEEDED per §3), and
  `tests.{buildDependencies,dependencies}` (only in the separate test
  derivation, so cppunit/tcl/pytest/fixtures never touch the main build's
  hash). nixpkgs' `depsBuildBuild…depsTargetTarget` exist for compilers
  that emit code for a third platform. With clang `--target` that is a
  flag. The one real `depsBuildBuild` use — compile a helper and run it
  during a cross build (ncurses tic, python \_freeze\_module) — is covered by
  an always-present `CC_FOR_BUILD` wrapper (same LLVM,
  `--target=<buildPlatform>`), not by a dependency list. Propagation is
  data (`exports.propagate`). python/node build systems fill it from
  `dependencies` automatically.
- Two package sets: `buildPackages` and `packages`. Cross is
  `load ./packages { platform = "riscv64-linux"; }`. No third ("target") platform, no six-way
  dependency lists, no splicing. Native is `buildPlatform == platform` on the same code
  path. CI builds every core package cross at least once.
- Dynamic glibc linking by default. `linkage = "static"` per package.
- GCC is a leaf package. Rust, Go, Zig use the same clang/lld and sysroots.
- CI matrix: native x86_64-v3 and aarch64. Cross from x86_64 to aarch64
  (checked against the native outputs — with CA most should be identical,
  the diff list is a reproducibility report) and to riscv64-linux (full
  core set, tests under qemu-user for a smoke subset). Toolchain + smoke
  package for wasm32-wasi, arm-none-eabi, riscv64-none-elf. x86_64-v2
  set built weekly, not per commit.
- Tests when cross-compiling: each platform record has
  `emulator = null | [ "qemu-riscv64" "-L" sysroot ] | [ "wasmtime" "--dir=." ] | …`
  taken from `buildPackages`. If `platform != buildPlatform` and an
  emulator exists, `tests.run` stays default-on and build systems wire it
  natively: cmake `CMAKE_CROSSCOMPILING_EMULATOR`, meson `exe_wrapper`,
  cargo `CARGO_TARGET_<TRIPLE>_RUNNER`, go `-exec`, autotools via a
  generated `LOG_COMPILER`. `core.nu` exports `PKGS_EMULATOR` for inline
  steps. Without an emulator (arm-none-eabi, riscv32-none-elf) `tests.run`
  defaults to false and CI reports it as "untested (no emulator)" rather
  than silently green. Measured in exp 10: explicit emulators only reach
  suites whose harness has a hook (ctest, meson, cargo, go). automake/
  libtool suites exec shell wrappers and need **transparent binfmt_misc**.
  So cross *test* derivations carry `requiredSystemFeatures =
  [ "binfmt-<arch>" ]` and CI builders register qemu-user with the F flag
  (NixOS `boot.binfmt.emulatedSystems`). Core detects it by executing the
  target `ld.so --version` (procfs is not visible in the sandbox) and then
  injects no emulator at all. With binfmt every riscv64 suite tried
  (oniguruma, xz, jq, zlib, lz4) passed unmodified. `tests.emulated = false` opts a package out when
  qemu-user is known-broken for it (threads+signals heavy suites), listed
  in CI like the flag opt-outs. riscv64-linux CI = cross build on x86_64 +
  qemu-user tests. A weekly native run on real hardware (or full-system
  qemu) catches emulator-masked bugs.


## 6. Interface and releases

### Consuming the set

Both entry points, same value:

```nix
# default.nix — no flakes needed, no fetching at import time
import ./. { platform = "x86_64-linux"; overrides = { }; config = { }; }
#  → { packages, buildPackages, lib, load, package, buildSystems, platforms }

# flake.nix — thin: outputs computed by calling default.nix per build platform
packages.<system>.<name>          # = (import ./. { platform = system; }).packages.<name>
legacyPackages.<system>           # the whole `packages` set incl. functions (`.override` verbs, `load`)
lib                               # platform-independent
devShells.<system>.<name>         # see §4 "Working on a package"
overlays.nixpkgs                  # bridge below
templates.{package,leaf-set}
```

`system` ↔ `platform`: flake `system` strings map to the default CPU level
(`x86_64-linux` → x86-64-v3). Other levels and cross targets are reached
through `legacyPackages.<system>.platforms.<platform>.packages` rather than
by inventing flake systems. No IFD, no `builtins.fetch*` during eval;
sources come from `lock.json` as fixed-output derivations, so pure eval and
`--offline` eval work.

Using it next to nixpkgs (NixOS, home-manager, devenv): outputs are
ordinary store paths, so `environment.systemPackages = [ pkgs-r.ripgrep ]`
just works. `overlays.nixpkgs` additionally exposes the set as
`pkgs.pkgsResearch` and offers `pkgsResearch.asNixpkgsInput drv` (adds the
`dev`/`lib` output aliases and a `pkg-config` wrapper path nixpkgs builders
expect) for the rare case of a nixpkgs derivation linking against one of
ours. The reverse (our packages depending on nixpkgs ones) is not
supported in core. Leaf sets may.

Binary cache: harmonia serving the CI store. CA derivations need the
realisations endpoint (`/realisations/*.doi`), which harmonia has. Signing
key per release line. `nix.settings.substituters`/`trusted-public-keys`
snippet in the README and in `templates`. Consumers without
`ca-derivations` enabled still substitute (outputs are plain paths). They
only lose early cutoff locally.

### Releases

- Core is rolling. The updater (llm-agents.nix style, declarative
  `extra.update` + `lock.json`) runs daily and opens PRs. CI is
  buildbot-nix on GitHub with a harmonia cache.
- Because outputs are CA, the merge queue can build everything.
- Stable = generated override tree pinning variant defaults + the CA cache.
- Leaf sets import core and use the same `package`. They may use
  `relocatable = false`.
- `meta.identifiers.{cpe,purl}` feed an eval-time SBOM manifest.

## 7. How the decisions were reached, and where the code went

Each of these was a throw-away experiment. The conclusions are in §1–6, the surviving code is in
the tree. Numbers are from a 16-core x86_64 builder.

| # | question | answer | now lives in |
|---|---|---|---|
| 1–4 | eval cost of package abstraction, overrides, lib | plain functions + one verb tree. 0.36 s / 1000 packages | `nix/package.nix`, `default.nix` |
| 5 | relocatable ELF without patching ld.so | link-time `crt_interp.o` + wrapper RUNPATH policy + in-place fixup. x86_64/aarch64/riscv64, gdb/perf fine | `cc/crt_interp.c`, `cc/jig.cc` (driver + `reloc-fixup`) |
| 6 | relocatable *closure* (python, openssl, curl) | only glibc gconv and openssl providers need dirname-relative patches. CA data ambient | `bootstrap/patches/glibc-gconv-relative.patch`, `pkgs/op/openssl/relocatable.patch` |
| 6b | compile cache inside the sandbox | daemon socket via `extra-sandbox-paths`. C (sqlite3.c 82 s → 0.08 s), Rust rlibs (fd 218 s → 1.4 s), Go (GOCACHEPROG). bit-identical, zero cost without socket | `cc/jig.cc`, `pkgs/ji/jig/cache-server.py` |
| 7 | can nu + clang build without sh/make | yes: musl, compiler-rt, libc++, dash, toybox from file lists. Make and kernel headers via their own scripts under that dash | `bootstrap/*.nu`, `pkgs/ll/llvm/` |
| 8 | builder API | blind LLM test of 5 variants: build systems as nu modules + name-only step list won 15/15. hooks/phases lost | `builder/`, `nix/build-systems.nix` |
| 9 | glibc with clang/lld | 2.43+ yes (2.44: 247 s). LAHF/MOVBE configure probes GCC-only (cache vars). Test delta vs gcc ≈ 35 real | `pkgs/gl/glibc/bootstrap.nu`, `platforms.nix` (`glibcConfigure`) |
| 10 | one LLVM for all targets | target is a flag. per-target = kernel headers, glibc, compiler-rt, libc++ (~5 min) vs ~39 min for a pkgsCross toolchain. lld RISC-V relaxation breaks IRELATIVE (`-mno-relax`) | `bootstrap/default.nix` stage1, `platforms.nix` |
| 12 | own seed | static-musl {nu, LLVM multicall, bsdtar, toybox} as 60 MB `nar.xz` via `<nix/fetchurl.nix>`. Eval cost irrelevant to the choice. Stage0 → `cc` in 6 min with no nixpkgs | `seed/`, `bootstrap/sources/`, `bootstrap/` stage0 |

Open:

- **11** CA payoff: replay three months of nixpkgs staging for the core set with Hydra NAR hashes as the oracle.
- stage1 → tools: cmake, ninja, python, perl, cargo, go … as packages so `standins.nix` empties. Then LLVM and nu themselves, seed rebuilt from the set, fixed-point check. aarch64 seed.
- jig: BLAKE3, link/bin-crate caching, configure-probe cache, verify sampling, remote CAS.
- glibc test-suite rerun on the own toolchain. Upstream reports (glibc x86 ISA probes, crt names with compiler-rt, lld RISC-V IRELATIVE).

## 8. Open decisions

1. **Runtime libs layout** (compiler-rt, libunwind, libc++, libc per
   `platform`). Options:
   (a) separate packages, wrapper passes several `-L`/`-isystem` and
   `-resource-dir` — maximal CA reuse (bumping libc++ does not touch
   compiler-rt), wrapper carries the complexity, include order bugs likely;
   (b) one `sysroot-<triple>` package that merges them (symlink tree) —
   single `--sysroot`, trivially correct search order, costs one cheap
   extra derivation per target and rebuilds the merge on any component
   bump (components themselves still cut off);
   (c) inside the LLVM output — simplest flags, but every rt change
   rebuilds the 2 GB LLVM output and all targets ride together.
   **Decided by exp 10: (b).** glibc, compiler-rt (as clang resource dir:
   builtins+crt+profile, clang headers merged in), llvm-runtimes
   (libunwind/libc++abi/libc++) are separate packages. `sysroot-<triple>`
   is a symlink view for `--sysroot`. The wrapper additionally knows the
   runtimes lib dir and gives it libc treatment (always-rpath when the C++
   driver links), because the driver links libc++ implicitly and no `-l`
   rule would catch it.
2. **glibc symbol-version policy.** nixpkgs builds against its current
   glibc only and makes no portability promise. Binaries need nixpkgs'
   glibc at runtime. Since we ship glibc relocatably in the closure the
   same policy works. A `portable` variant targeting old symbol versions is
   only needed if "copy one binary to a foreign distro without its closure"
   becomes a goal. Default: current only.
3. **`openssl.version.set` semantics.** (a) patch the default variant's
   `version` (URL template re-evaluates, `source.hash` must be set too;
   flexible, but a typo silently builds a different thing than an existing
   variant). (b) select an existing variant by version, error otherwise
   (safe, but cannot express "try 3.3.2 which we don't package");
   (c) forbid, use `openssl.default.set = "v3_3"` to select and
   `openssl.source.set`/`lock` to introduce versions. Leaning (c): two
   explicit operations, no guessing.
4. **Scoped dependency rewrites** ("git uses curl-with-zlib-ng"). Named
   extra packages (`packages.curl-ng = { from = "curl"; dependencies.zlib.set
   = "zlib-ng". }. git.dependencies.curl.set = "curl-ng";`) are better for
   both eval and LLMs than inline `with`: the variant is instantiated once
   and shared by every user, has a name in errors/CI/cache, and the tree
   stays flat with string references. Inline `with` would create anonymous
   duplicates per use site. Decision pending a check that `from` cloning
   stays O(1) extra package.
5. ~~Ecosystem lock data at scale~~ decided: dynamic derivations (§1
   Sources). Nothing per-crate in the repo or the eval, per-crate sharing
   in the store. Cost: CppNix with two experimental features on the
   builders, Lix cannot build these packages today.
6. **Parse floor.** 0.1 ms/file is accepted for 1k packages. For larger
   sets rely on an evaluator-side cache/pack-file store rather than
   generating concatenated Nix.
7. ~~Build-system `-rpath` policy~~ decided by experiment 5: store and
   build-tree rpaths pass at link, `/usr` dirs error, fixup keeps store only.

## 9. Sources

Adopted: Ekala EEPs (path = attr, autoCall, variants, explicit hooks,
named deps and nested sets, update policy, frozen defaults, SBOM meta, devshell
from package). Aux tidepool (eval-time context/exports, identical native
and cross path, `with`/`rec` ban). Corepkgs (tests split from build);
korora. Nuenv. zig (LLVM target-as-flag). Spack/conda/Guix (relocation);
wrap-buddy (entry-stub idea; we replace its loader with a link-time
stub). Fzakaria (relocatable binaries, harden
DT_NEEDED). llm-agents.nix (declarative updater + lock files). RFC 62.

To read: EEP-43 batch cache protocol, snix build protocol, zb Lua frontend
numbers, Guix `search-paths`, Chimera Linux patches, live-bootstrap for seed
provenance.
