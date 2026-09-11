# repkgs

An experimental package set on stock Nix. It keeps the store and the language and changes what
goes into a derivation. The *re-* is for relocatable, reproducible, and having another go at
nixpkgs.

- **One toolchain.** A single LLVM (clang, lld, compiler-rt, libc++) targets every platform.
  Cross compiling is `--argstr platform riscv64-linux`, not a second compiler.
- **Relocatable outputs.** Binaries find their libraries relative to themselves. A store path
  copied elsewhere still runs, and upstream prebuilt binaries get the same treatment.
- **Nushell builders.** No bash, no setup hooks, no string-typed phases. A build system is a
  small nu module with `configure`, `build`, `test` and `install` phases.
- **A compile cache below Nix.** `cc`, `rustc`, `go` and configure probes are cached by content
  on the host, across derivations. Change a recipe and the derivation rebuilds, but almost
  nothing recompiles. The cache is a socket in the sandbox and not an input, so `.drv` hashes
  are the same with or without it.
- **Cheap evaluation.** A package is a small attribute set that gets its arguments by name, as
  with `callPackage`. There are no overlays and no per-package fixpoints. Overrides are one
  directory tree, out-of-tree packages one argument.
- **Short bootstrap.** A small static seed reaches glibc in two stages. Rust, Go, Zig, GHC and
  OpenJDK are then built from source, each starting from its upstream binary.

[docs/design.md](docs/design.md) explains why for each of these. [docs/plan.md](docs/plan.md)
is what comes next.

## Try it

Dynamic derivations need a recent Nix daemon: 2.36, or a 2.36pre from August 2026 on. nixpkgs'
`nixVersions.git` is one. On NixOS:

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
$ nix-build bootstrap -A stage1.x86_64.cc           # just the toolchain
```

The first build fetches the seed and builds the toolchain. Everything after that is incremental.

`repkgs` (tools/, on PATH with direnv) wraps the common tasks, `repkgs <cmd> --help` says what
each runs:

```console
$ repkgs cache start                     # the compile cache daemon (jigd), optional
$ repkgs build jq                        # nix-build with the cache socket mapped into the sandbox
$ repkgs build --for aarch64-linux jq    # cross
$ repkgs test jq                         # jq.tests
$ repkgs log jq                          # the build log
$ repkgs list --for riscv64-linux --unsupported   # what a platform lacks and why
$ repkgs info deno                       # version, build systems, platform support
$ repkgs options cmake                   # every cmake.* option with type and default
$ repkgs new foo pkg:github/o/foo 'https://…/foo-{version}.tar.gz'
$ repkgs update check                    # uptrack: what is outdated
$ repkgs repro zlib                      # rebuild and compare
```

Mapping the cache socket is a per-build `extra-sandbox-paths`, so your user has to be in
`nix.settings.trusted-users`. Build logs then end in a line like `jig: cc cached=812/815 (99%) compiled=3`.

## Writing a package

A package is a directory with two files:

```
pkgs/li/libpng/
├── package.nix     how to build it
└── sources.toml    where it comes from: upstream id, URL template, pinned version and hash
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

`sources.toml` supplies version and tarball. `uses` names the build system, and the build system
brings its tools, its phases (configure, build, test, install) and its options. Options
are things like `cmake.defs` above, `cargo.features` or `go.tags`, and every build system has
`<name>.tool` to swap the program itself (`cargo.tool = buildPkgs.rust-bootstrap`).
`repkgs options cmake` lists them. Their names and types are checked at evaluation time, so a typo is an error instead of an
attribute nobody reads.

A package with build-time tools and its tests turned off, curl:

```nix
{ package, pkgs, buildPkgs }:
package {
  name = "curl";
  uses = [ "cmake" ];
  cmake.defs = { CURL_USE_OPENSSL = true; CURL_CA_PATH = "/etc/ssl/certs"; };
  dependencies = [ pkgs.openssl pkgs.zlib pkgs.zstd ];   # linked, target platform
  buildDependencies = [ buildPkgs.perl ];                # run during the build, build platform
  tests.run = false;                                     # the suite wants python and minutes
}
```

Dependencies are found through the ordinary search paths (`-I`, `-L`, pkg-config, cmake), so
the package says nothing more about them. `patches = [ ./x.patch ]` are applied after unpacking.
`bin = [ "rg" ]` names the executables when they differ from the package name.

Lock files need no translation. For Cargo, Go, npm, pnpm, Yarn, Bundler, Deno, Hex, Hackage and
LuaRocks, the lock file in the source is turned into fixed-output fetches at build time, by a
dynamic derivation, with the hashes the lock file already has. Where it has none (Go, Hackage,
LuaRocks) they are kept in `locks/*.toml`.

If a package needs something between or instead of those, it writes `phases` out. Each entry
is either a phase of the build system or a piece of nu with a name. Inside the nu, `$c` holds the
paths and facts of the build (`$c.out`, `$c.src`, `$c.build`, `$c.njobs`, `$c.platform`):

```nix
phases = [
  "autotools.configure"
  "autotools.build"
  { name = "trim"; run = ''rm $"($c.out)/bin/unwanted"''; }
  "autotools.install"
];
```

Phases too long to keep inline can live in their own file: `modules.rust = ./build.nu;` makes it
a module, and `phases` refers to them as `"rust.configure"`. pkgs/ru/rust does this.

Every build ends the same way. ELF outputs are made relocatable. `bin/<name> --version` runs in
an empty environment and has to print the pinned version. A `dlopen` that finds nothing during
that run fails the build, unless `tests.dlopen = [ "libudev.so.1" ]` declares it optional.
`tests.relocated = true` repeats the run from a copy of the output at another path, and
`tests.separate = true` puts the test phase in its own derivation.

Hardening and `-O2 -g` are compiler defaults, injected by the driver and not through `CFLAGS`.
`cc.hardening.fortify = false` turns one off, `cc.cflags = [ "-DFOO" ]` (and `cxxflags`,
`ldflags`) adds to every compile regardless of build system.

A few fields are rarer. `prebuilt = true` takes an upstream binary and only makes it
relocatable. `install."bin/deno" = "deno"` copies files with no phases at all.
`exports.propagate = [ pkgs.pcre2 ]` is for a library whose users must also see another, a
`Requires:` line in its .pc file. `exports = false` marks toolchains and applications that
nothing links against.

## Keeping it current

`uptrack` (pkgs/up/uptrack, also `repkgs update …`) reads every `sources.toml`, asks upstream
for new versions, and rewrites pin and hash:

```console
$ uptrack check          # what is outdated
$ uptrack apply zlib     # bump, prefetch, update the hash
$ uptrack lock fzf       # refresh locks/go.toml from its go.sum
```

More in [docs/uptrack.md](docs/uptrack.md).

## Repository layout

```
pkgs/xx/<name>/   the packages, xx being the first two letters. Some hold more than
                  package.nix: bootstrap.nu (a toolchain recipe), src/ (in-tree programs), patches
bootstrap/        seed → stage0 (musl cc) → stage1 (glibc cc, one per platform)
nix/              evaluation. package.nix turns a spec into a derivation, build-systems.nix
                  defines each `uses` entry, fetch.nix the lock-file fetchers
builder/          build time. prepare, finish, and one nu module per build system
locks/            hashes that lock files lack (go.sum, hackage, luarocks)
docs/             design.md (why), uptrack.md, plan.md
tools/repkgs      the cli: build, test, log, list, info, options, new, update, repro, cache, seed, fmt
```

Four in-tree programs hold this together. **jig** (pkgs/ji/jig, C++) is what `cc` and `rustc`
resolve to inside a build: compiler driver, cache client and ELF fixup in one binary. **jigd**
(pkgs/ji/jigd, Go) is the per-machine daemon behind the socket, holding the cache and the build
slots. **launch** and **crt-interp** are the few hundred bytes that let scripts and ELF binaries
run from any path. **uptrack** (nu) does the updates.

## How the bootstrap goes

```
seed        static nu, clang, lld, bsdtar, toybox, make …
→ stage0    musl + libc++ + jig: a C/C++ compiler for the build machine
→ stage1    glibc + compiler-rt + libc++: cc-<platform>, one per target
→ pkgs/*
→ rust, go, zig, ghc, jdk: the upstream binary as <lang>-bootstrap, then built from source
```

The seed itself is reproducible from `pkgs/se/seed/build.nix`.
