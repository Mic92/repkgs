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

The daemon needs Nix master with [NixOS/nix#16459](https://github.com/NixOS/nix/pull/16459);
[#16465](https://github.com/NixOS/nix/pull/16465) and
[#16477](https://github.com/NixOS/nix/pull/16477) recommended (CA rebuilds after gc). [nix/nix](nix/nix/default.nix)
builds it (`nix-build nix/nix`, flake `packages.x86_64-linux.nix`). On NixOS:

```nix
nix.package = inputs.repkgs.packages.${pkgs.system}.nix; # or: import "${repkgs}/nix/nix" { inherit pkgs; }
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

`repkgs` (on PATH with direnv) wraps the common tasks; [tools/repkgs/README.md](tools/repkgs/README.md)
has all of them:

```console
$ repkgs build jq                        # through the compile cache (repkgs cache start)
$ repkgs build --for aarch64-linux jq    # cross
$ repkgs test jq                         # jq.tests
$ repkgs dev jq                          # a failing build by hand, in a tree that stays
$ repkgs info deno                       # version, build systems, platform support
```

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

If a package needs something between or instead of those, `phases` edits the build system's
list: `before.<phase>`, `after.<phase>`, `replace.<phase>` take a phase or a list, `remove` a
list. A phase is one of a build system's or a piece of nu with a name. Inside the nu, `$c` holds
the paths and facts of the build (`$c.out`, `$c.src`, `$c.build`, `$c.njobs`, `$c.platform`):

```nix
phases.after."autotools.install" = { name = "sh-alias"; run = ''^ln -s bash $"($c.out)/bin/sh"''; };
phases.replace."autotools.configure" = "perl.configure";
phases.remove = [ "cargo.test" ];
```

`phases = [ … ]` spells the whole list out instead. With several build systems the edits apply
to the first one's list.

Phases too long to keep inline can live in their own file: a phase `"rust.configure"` whose
prefix is no build system is `rust.nu` next to package.nix. pkgs/ru/rust does this.

Every build ends the same way. ELF outputs are made relocatable. `bin/<name> --version` runs in
an empty environment and has to print the pinned version. A `dlopen` that finds nothing during
that run fails the build, unless `tests.dlopen = [ "libudev.so.1" ]` declares it optional.
The run is repeated from a copy of the closure under another root. `tests.separate = true` puts
the test phase in its own derivation.

Hardening and `-O2 -g` are compiler defaults, injected by the driver and not through `CFLAGS`.
`cc.hardening.fortify = false` turns one off, `cc.cflags = [ "-DFOO" ]` (and `cxxflags`,
`ldflags`) adds to every compile regardless of build system. Debug info lands in a separate
`debug` output by build-id (`nix-build -A curl.debug`, then
`gdb -iex "set debug-file-directory ./result-debug/lib/debug"`).

Choices a user may want to make differently are `features`. The package declares them with a
default and reads the chosen values back:

```nix
{ package, pkgs, features, on }:
package {
  name = "curl";
  features = {
    tls = { values = [ "openssl" "gnutls" "none" ]; default = "openssl"; doc = "TLS backend"; };
    http3 = { default = false; };
  };
  dependencies = on (features.tls != "none") [ pkgs.${features.tls} ] ++ on features.http3 [ pkgs.ngtcp2 ];
  cmake.defs.USE_NGTCP2 = features.http3;
}
```

A feature has the type of its default. `values` lists what a string, or each element of a list,
may be. To choose:
`import ./. { features.tls = "gnutls"; }` sets it for every package that declares `tls`,
`overrides.curl.features.http3 = true` for curl alone. `repkgs info curl` lists a package's
features and their current values.

A few fields are rarer. `prebuilt = true` takes an upstream binary and only makes it
relocatable. `install."bin/deno" = "deno"` copies files with no phases at all.
`completions.bash = [ "completions/foo.bash" ]` (and `zsh`, `fish`, `nu`) installs shell
completions to their standard directories (`nu` to nushell's vendor autoload).
`exports.propagate = [ pkgs.pcre2 ]` is for a library whose users must also see another, a
`Requires:` line in its .pc file. `exports = false` marks toolchains and applications that
nothing links against.

## Keeping it current

`uptrack` (pkgs/up/uptrack, also `repkgs update …`) reads every `sources.toml`, asks upstream
for new versions, and rewrites pin and hash:

```console
$ uptrack check          # what is outdated
$ uptrack apply zlib     # bump, prefetch, update the hash (--commit: one commit per bump)
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
tests/builder/    tiny packages per language that check what builder/ does to them (`repkgs test`)
docs/             design.md (why), uptrack.md, plan.md
tools/repkgs/     the cli (its README.md is for changing it)
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

## License

MIT, see [LICENSE](LICENSE). Patches under `pkgs/` carry the license of the project they apply to.
