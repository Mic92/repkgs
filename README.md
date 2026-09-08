# pkgs

A small package set for stock Nix: ~1k packages, x86_64/aarch64-linux (+ cross riscv64),
one LLVM toolchain with target-as-a-flag, glibc, nushell as the only build language,
relocatable outputs, low eval cost. Design and rationale: [docs/design.md](docs/design.md).

```
nix-build -A jq                                     # build machine's platform
nix-build -A jq --argstr platform riscv64-linux     # cross
nix-build -A jq.tests                               # packages with tests.separate
nix-build bootstrap -A stage1.x86_64.cc             # just the toolchain
```

## Layout

Every named thing is a directory under `pkgs/`. Everything else is machinery, in the order it is used:

```
bootstrap/   default.nix: seed → stage0 (musl cc for the build machine) → stage1 cc-<platform> (glibc).
             run.nu, lib.nu, sysroot.nu. Per-package recipes are pkgs/xx/<name>/bootstrap.nu
nix/         eval time: package.nix (spec → derivation), build-systems.nix (what `uses` means),
             sources.nix (reads sources.toml), fetch.nix (cargo/npm/go dependency fetchers), platforms.nix
builder/     build time, one nu process per package: core/prepare/finish/launchers.nu, one module per
             build system (cmake.nu, cargo.nu …), fetch-{cargo,npm}.nu for the dynamic derivations
pkgs/xx/<name>/ (xx = first two letters) any of: sources.toml (upstream pin), package.nix (set member), bootstrap.nu (stage0/1 recipe),
             update.nu (uptrack hook), src/ (in-tree source), patches and data files.
             Language lines are separate names (cpython314); pkgs/aliases.toml maps cpython → the default line
docs/        design.md (why), uptrack.md (updates), plan.md (what is next)
default.nix  { platform } → the set;  standins.nix  the one `import <nixpkgs>` left (docs/plan.md)
```

In-tree programs: `pkgs/ji/jig` (compiler entry point, compile cache client, ELF fixup, Nix
worker-protocol client, plus `cache-server.py`), `pkgs/la/launch` (the static launcher behind every
script), `pkgs/cr/crt-interp` (the PT_INTERP stub linked into every executable), `pkgs/up/uptrack`
(the update tool), `pkgs/se/seed/build.nix` (rebuilds the binary seed). `pkgs/ll/llvm` carries the
toolchain recipes (compiler-rt, runtimes, cc) and compiler-rt's generated file lists.

## Writing a package

```nix
# pkgs/li/libpng/package.nix (version and source come from sources.toml beside it)
{ package, pkgs }:
package {
  name = "libpng";
  uses = [ "cmake" ];
  cmake.defs = { PNG_STATIC = false; PNG_TOOLS = true; };
  dependencies = [ pkgs.zlib ];
  exports.propagate = [ pkgs.zlib ];
}
```

`sources.toml` beside it names the upstream (`purl`), the URL template and the pinned
version+hash. `pkgs/up/uptrack/src/uptrack init pkgs/li/libpng pkg:github/pnggroup/libpng <url>` writes it,
`uptrack check` / `apply` keep it current (docs/uptrack.md).

Fields: `name version source patches uses steps dependencies buildDependencies
runtimeDependencies bin tests.{run,separate,skip,parallel,version,relocated} exports env root cc.cflags bootstrapTools` plus one
attrset per build system in `uses` (knobs listed in `nix/build-systems.nix`, unknown fields and
knobs are eval errors). `steps` defaults to the build system's. Entries are `"<bs>.<verb>"` or
`{ name, run = "<nu>" }`. Inside `run`, `(ctx)` gives `src build out deps njobs platform`.

## Bootstrap chain

```
seed.nar.xz     static nu, LLVM multicall, bsdtar, toybox, dash, make, gawk/sed/grep/m4/bison, python
            ──► stage0 (musl):  musl-headers → compiler-rt → musl → linux-headers
                                → libunwind/libc++abi/libc++ → jig → cc            (~3 min)
            ──► stage1 (glibc, per platform, built by stage0 cc + seed tools, through jig):
                                linux-headers → glibc-headers → compiler-rt(+profile) → glibc
                                → libunwind/libc++abi/libc++ → cc-<platform>   (~5 min, ~2.5 cached)
            ──► pkgs/*
```

Everything after stage0's `jig` compiles through the compile cache (below) in content-identity
mode, so editing a recipe rebuilds the derivations but recompiles almost nothing.

`NIX_PATH= nix-build bootstrap -A stage0.cc` evaluates (70 ms, 1.2k thunks) and builds with
nothing but Nix and the network. The seed is rebuilt by `pkgs/se/seed/build.nix` (today from nixpkgs
pkgsStatic, later from this set's own musl-static packages) and pinned in `pkgs/se/seed/sources.toml`.

## Compile cache

Optional and transparent: if `/run/pkgs-cache.sock` exists in the sandbox
(`--option extra-sandbox-paths /run/pkgs-cache.sock=/path/to/sock`, daemon:
`python3 pkgs/ji/jig/cache-server.py /path/to/sock`), `cc` caches C/C++ objects, `rustcwrap` rlibs and
`gocacheprog` Go actions, keyed on content + flags. Without the socket everything compiles normally.
Each build log ends with a `cache` line (`hit=812 miss-stored=3 plain=40 …`). To never forget the
option, put `extra-sandbox-paths = /run/pkgs-cache.sock=/path/to/sock` in `nix.conf`.
