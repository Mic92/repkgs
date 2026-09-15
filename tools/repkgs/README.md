# repkgs

The command line for working on the package set. With direnv it is on PATH; otherwise
`tools/repkgs/repkgs`. Every subcommand has `--help`, and `--for <platform>` where a platform
makes sense (`aarch64-linux`, `aarch64-macos`, `x86_64-windows-msvc`, …).

## Everyday

```console
$ repkgs build jq                     # build, through the compile cache if jigd runs
$ repkgs build --for aarch64-macos jq # cross
$ repkgs test jq                      # jq.tests, or jq itself when it tests in-build
$ repkgs test                         # the builder's own tests, after editing builder/
$ repkgs log jq                       # the last build log
$ repkgs info jq                      # version, platforms, build systems, features (--json)
$ repkgs list --for riscv64-linux --unsupported   # what a platform lacks and why
$ repkgs options cmake                # every cmake.* a package.nix may set, with defaults
$ repkgs fmt                          # treefmt
```

## When a build fails

```console
$ repkgs dev perl                     # or --for aarch64-macos perl
```

drops you into a nu shell in the unpacked, patched source with the build's environment: same
PATH, compiler, flags and dependencies as the sandbox. The build's phases are commands:

```console
> phases                              # perl.configure autotools.build autotools.install perl.scrub
> phase perl.configure
> phase autotools.build               # fails somewhere in dist/Time-HiRes
> ^make -C dist/Time-HiRes            # go at it directly, edit files, repeat
> exit
$ repkgs dev perl 'phase autotools.build'   # back later: tree and edits are still there
$ repkgs dev --reset perl             # fresh source, same tree
$ repkgs dev --fresh perl             # remove everything
```

The tree is `~/.cache/repkgs/dev/<pkg>-<platform>/` (`source/`, `build/`, `prefix/` for what
install puts down). It is not sandboxed: network and the host's /usr are visible, so confirm a
fix with `repkgs build`. If the package or the builder changed since the last entry, inputs are
rebuilt as needed on the way in; the source tree is left alone until `--reset`.

Once the fix is clear, turn the edit into a patch next to package.nix (`diff -u` against a
pristine unpack, or `git format-patch` from an upstream checkout) and build for real.

## The compile cache

```console
$ repkgs cache start                  # jigd, per user, under /tmp/jigd-<uid>/
$ repkgs cache status
$ repkgs cache stop
```

`build`, `test`, `dev` and `repro` use it when the socket is there. A daemon elsewhere:
`JIG_SOCK=/path/to/socket repkgs …`. Mapping the socket into the sandbox needs your user in
`nix.settings.trusted-users`.

## Adding and updating packages

```console
$ repkgs new foo pkg:github/o/foo 'https://…/foo-{version}.tar.gz'   # pkgs/fo/foo/ with sources.toml
$ repkgs update check                 # what is outdated (uptrack)
$ repkgs update apply foo             # new pin and hashes
$ repkgs repro zlib                   # build twice, compare
```

## Rare

```console
$ repkgs seed …                       # rebuild and upload the bootstrap seed
$ repkgs bootstrap ghc riscv64-linux  # cross-build a -bootstrap package's binary and upload it
```

## Files

`repkgs` is the entry point, `nix.nu` what all subcommands share (nix flags, eval helpers, cache
socket), `dev.nu` is `repkgs dev`. Comments in dev.nu explain how it reuses the derivation's own
script and resolves content-addressed inputs.
