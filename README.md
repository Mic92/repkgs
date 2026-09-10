# repkgs

An experimental package set for stock Nix that revisits a few nixpkgs fundamentals
(re- as in relocatable, reproducible, and nixpkgs once more):

- **One toolchain.** A single LLVM (clang, lld, compiler-rt, libc++) targets every platform.
  Cross compiling is a flag, not a second compiler: `--argstr platform riscv64-linux`.
- **Relocatable outputs.** Binaries find their libraries relative to themselves, so a store
  path can be copied anywhere and still run. Even upstream prebuilt binaries get this treatment.
- **Nushell builders.** No bash, no setup hooks, no string-typed phases. Each build system is a
  small nu module with `configure / build / test / install` verbs.
- **A compile cache below Nix.** `cc`, `rustc`, `go` and configure probes are cached by content
  on the host, across derivations. Changing a recipe rebuilds the derivation but recompiles
  almost nothing. It sits behind a socket in the sandbox and is no input of any derivation:
  the same .drv hashes with or without it.
- **Cheap evaluation.** A package is a small attrset. One override tree and a `packages`
  argument for out-of-tree ones instead of overlays, no fixpoints per package, arguments passed
  by name as with `callPackage`, nothing more.
- **Bootstrapped from a small static seed** to glibc in two short stages, and languages
  (Rust, Go, Zig, GHC, OpenJDK) built from source on top, each seeded by its upstream binary.

The reasoning behind each of these is in [docs/design.md](docs/design.md). What is planned
next is in [docs/plan.md](docs/plan.md).

## Try it

The **Nix daemon** has to be new enough for dynamic derivations: 2.36 or a 2.36pre from August
2026 on (nixpkgs `nixVersions.git` qualifies). As NixOS configuration:

```nix
nix.package = pkgs.nixVersions.git;
nix.settings = {
  experimental-features = [ "nix-command" "ca-derivations" "dynamic-derivations" "recursive-nix" ];
  system-features = [ "builder-rpc-v0" "big-parallel" "kvm" "nixos-test" "benchmark" ];
};
```

Then:

```console
$ nix-build -A jq                                   # for this machine
$ nix-build -A jq --argstr platform aarch64-linux   # cross
$ nix-build -A ripgrep -A fd -A deno -A pandoc      # cargo, prebuilt, haskell …
$ nix-build bootstrap -A stage1.x86_64.cc           # only the toolchain
```

The first build fetches the seed and builds the toolchain, everything after that is incremental.

To get the compile cache, run the daemon once and let the sandbox see its socket. Mapping the
socket in is a per-build `extra-sandbox-paths`, which the Nix daemon only accepts from
`nix.settings.trusted-users`:

```console
$ nix-build -A jigd && ./result/bin/jigd $XDG_RUNTIME_DIR/jigd/socket &
$ tools/build -A jq     # nix-build with the socket mapped into the sandbox, no remote builders
```

Every build log then ends in a line like `jig: cc cached=812/815 (99%) compiled=3` (jig is the
compiler driver, see below).

## Writing a package

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

Version and tarball come from `sources.toml`. `uses` picks the build system, which brings its
tools, its default steps (`configure build test install`) and its options: `cmake.defs` above,
`cargo.features`, `go.tags` and so on. `tools/options cmake` lists them. Option names and types
are checked at evaluation time, so a typo is an error and not a silently ignored attribute.

With more of the vocabulary (pkgs/cu/curl, abridged):

```nix
{ package, pkgs, buildPkgs }:
package {
  name = "curl";
  uses = [ "cmake" ];
  cmake.defs = { CURL_USE_OPENSSL = true; CURL_CA_PATH = "/etc/ssl/certs"; };
  dependencies = [ pkgs.openssl pkgs.zlib pkgs.zstd ];   # linked, target platform
  buildDependencies = [ buildPkgs.perl ];                # run during the build, build platform
  tests.run = false;                                     # the suite needs python and minutes
}
```

`dependencies` are found through the usual search paths (`-I`, `-L`, pkg-config, cmake) with
nothing to write in the package. `patches = [ ./x.patch ]` apply after unpacking, and
`bin = [ "rg" ]` names the executables that must exist when they differ from the package name.
Lock-file ecosystems (Cargo, Go, npm, pnpm, Yarn, Bundler, Deno, Hex, Hackage, LuaRocks) need
nothing either: the lock file in the source becomes fixed-output fetches at build time, through
dynamic derivations and the hashes the lock file already carries. Hashes it lacks (Go, Hackage,
LuaRocks) are kept in `locks/*.toml`.

When the default steps do not fit, `steps` says what runs. Build system verbs and inline nu mix
freely, and `$c` is the build context (`out src build njobs platform spec deps`):

```nix
steps = [
  "autotools.configure"
  "autotools.build"
  { name = "trim"; run = ''rm $"($c.out)/bin/unwanted"''; }
  "autotools.install"
];
```

Longer nu goes into a module of its own: `modules.rust = ./build.nu;` and steps call its verbs as
`"rust.configure"` (see pkgs/ru/rust).

Every build ends with the same checks: ELF outputs are made relocatable, `bin/<first> --version`
runs in an empty environment and has to print the pinned version, and a `dlopen` that finds
nothing during that run fails the build (`tests.dlopen = [ "libudev.so.1" ]` allows an optional
one). `tests.relocated = true` repeats the version run from a copy of the output somewhere else,
`tests.separate = true` moves the test step into a derivation of its own.

The less common fields: `prebuilt = true` for an upstream binary that is only made relocatable,
`install."bin/deno" = "deno"` to copy files without any steps, `exports.propagate = [ pkgs.pcre2 ]`
for a library whose users need another one too (a `Requires:` line in its .pc file), and
`exports = false` for toolchains and applications nobody links against.

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
locks/            hashes lock files do not carry (go.sum, hackage, luarocks)
docs/             design.md (why), uptrack.md, plan.md
```

The in-tree programs that make this work: **jig** (`pkgs/ji/jig`, C++) is the `cc`/`rustc`
entry point, cache client and ELF fixup tool. **jigd** (`pkgs/ji/jigd`, Go) is its host side: the
per-machine daemon with the compile cache and the build slots. **launch** and **crt-interp** are the few hundred bytes that make scripts
and ELF binaries relocatable. **uptrack** (nu) does updates.

## How the bootstrap goes

```
seed (static: nu, clang/lld, bsdtar, toybox, make …)
  → stage0: musl + libc++ + jig → a C/C++ compiler for the build machine
  → stage1: glibc + compiler-rt + libc++ → cc-<platform>, one per target
  → pkgs/*
  → rust, go, zig, ghc, jdk: upstream binary as <lang>-bootstrap → built from source
```

The seed itself is reproducible from `pkgs/se/seed/build.nix`.
