# pkgs

An experimental package set for stock Nix that revisits a few nixpkgs fundamentals:

- **One toolchain.** A single LLVM (clang, lld, compiler-rt, libc++) targets every platform.
  Cross compiling is a flag, not a second compiler: `--argstr platform riscv64-linux`.
- **Relocatable outputs.** Binaries find their libraries relative to themselves, so a store
  path can be copied anywhere and still run. Even upstream prebuilt binaries get this treatment.
- **Nushell builders.** No bash, no setup hooks, no string-typed phases. Each build system is a
  small nu module with `configure / build / test / install` verbs.
- **A compile cache below Nix.** `cc`, `rustc`, `go` and configure probes are cached by content
  on the host, across derivations. Changing a recipe rebuilds the derivation but recompiles
  almost nothing. Optional. Derivations do not mention it.
- **Cheap evaluation.** A package is a small attrset. No overrides, no fixpoints per package,
  arguments passed by name as with `callPackage`, nothing more.
- **Bootstrapped from a small static seed** to glibc in two short stages, and languages
  (Rust, Go, Zig, GHC, OpenJDK) built from source on top, each seeded by its upstream binary.

The reasoning behind each of these is in [docs/design.md](docs/design.md). What is planned
next is in [docs/plan.md](docs/plan.md).

## Try it

Needs Nix with `experimental-features = nix-command ca-derivations dynamic-derivations`.

```console
$ nix-build -A jq                                   # for this machine
$ nix-build -A jq --argstr platform aarch64-linux   # cross
$ nix-build -A ripgrep -A fd -A deno -A pandoc      # cargo, prebuilt, haskell …
$ nix-build bootstrap -A stage1.x86_64.cc           # only the toolchain
```

The first build fetches the seed and builds the toolchain (about 8 minutes), everything after
that is incremental.

To get the compile cache, run the daemon once and let the sandbox see its socket:

```console
$ nix-build -A pkgs-cache && ./result/bin/pkgs-cache /tmp/pkgs-cache.sock &
$ echo 'extra-sandbox-paths = /run/pkgs-cache.sock=/tmp/pkgs-cache.sock' >> ~/.config/nix/nix.conf
```

Every build log then ends in a line like `cache: hit=812 miss-stored=3`.

## What a package looks like

```
pkgs/li/libpng/
├── package.nix     how to build it
└── sources.toml    where it comes from: upstream id, URL template, pinned version + hash
```

```nix
{ package, pkgs }:
package {
  name = "libpng";
  uses = [ "cmake" ];
  cmake.defs = { PNG_STATIC = false; PNG_TOOLS = true; };
  dependencies = [ pkgs.zlib ];
}
```

Version and tarball come from `sources.toml`, the steps come from the
build system named in `uses`, and its knobs (`cmake.defs` here) are checked at eval time, so
a typo is an error rather than a silently ignored attribute.

When the defaults do not fit, `steps` lists what runs, mixing build system verbs with inline nu:

```nix
steps = [
  "autotools.configure"
  "autotools.build"
  { name = "fixup"; run = ''rm $"($c.out)/bin/unwanted"''; }   # $c: out, src, build, njobs, platform, spec
  "autotools.install"
];
```

Other things a package can say, by example:

| | |
|---|---|
| `buildDependencies = [ buildPkgs.cpython ];` | tools that run during the build (build platform) |
| `dependencies = [ pkgs.openssl ];` | libraries to link (target platform), found via the usual search paths |
| `cargo.features = [ "pcre2" ];` | build system knobs, listed per system in `nix/build-systems.nix` |
| `bin = [ "rg" "rgrep" ];` | executables that must exist. Defaults to the package name. `bin/<first> --version` must print the pinned version |
| `tests.relocated = true;` | repeat that check after copying the output somewhere else |
| `prebuilt = true;` | upstream binary: skip compiling, make it relocatable anyway |
| `install."bin/deno" = "deno";` | just copy files into `$out`, no steps needed |
| `exports = false;` | a toolchain or application: dependents should not link against its lib/ |
| `patches = [ ./fix.patch ];` | applied with `patch -p1` after unpacking |

Lock-file ecosystems (Cargo, Go, npm, pnpm, Yarn, Bundler, Deno, Hackage) need nothing in the
package: the lock file in the source is turned into fixed-output fetches at build time through
dynamic derivations, using the hashes the lock file already carries. Hashes it lacks (Go, Hackage)
live in `locks/*.toml`, filled in by `uptrack lock`.

## Keeping it current

`uptrack` (in `pkgs/up/uptrack`) reads every `sources.toml`, asks the upstreams for new versions,
and rewrites pin and hash:

```console
$ uptrack check          # what is outdated
$ uptrack apply zlib     # bump it, prefetch, update the hash
$ uptrack lock fzf       # refresh locks/go.toml for its go.sum
```

Details in [docs/uptrack.md](docs/uptrack.md).

## Repository layout

```
pkgs/xx/<name>/   the packages (xx = first two letters). Some carry more than package.nix:
                  bootstrap.nu (toolchain recipe), src/ (in-tree programs), patches
bootstrap/        seed → stage0 (musl cc) → stage1 (glibc cc per platform)
nix/              evaluation: package.nix turns a spec into a derivation, build-systems.nix
                  says what each `uses` entry means, fetch.nix does the lock-file fetchers
builder/          build time: prepare/finish and one nu module per build system
locks/            hashes lock files do not carry (go.sum, hackage)
docs/             design.md (why), uptrack.md, plan.md
```

The in-tree programs that make this work: **jig** (`pkgs/ji/jig`, C++) is the `cc`/`rustc`
entry point, cache client and ELF fixup tool. **pkgs-cache** (`pkgs/pk/pkgs-cache`, Go) is the
host-side cache daemon. **launch** and **crt-interp** are the few hundred bytes that make scripts
and ELF binaries relocatable. **uptrack** (nu) does updates.

## How the bootstrap goes

```
seed (static: nu, clang/lld, bsdtar, toybox, make …)
  → stage0: musl + libc++ + jig → a C/C++ compiler for the build machine        ~3 min
  → stage1: glibc + compiler-rt + libc++ → cc-<platform>, one per target        ~5 min
  → pkgs/*
  → rust, go, zig, ghc, jdk: upstream binary as <lang>-bootstrap → built from source
```

The seed itself is reproducible from `pkgs/se/seed/build.nix`.
