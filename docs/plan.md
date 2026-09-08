# Plan

What design.md does not describe yet because it is not built. `standins.nix` is gone: every build
tool is a package; nixpkgs remains only in shell.nix/treefmt.nix and pkgs/se/seed/build.nix.

## Next

**Rust from source.** Today's `rust` (upstream binaries, `prebuilt`) becomes `rust-bootstrap`,
only a build dependency of `rust`: rustc + cargo from the rustc-src tarball with `x.py` against our
LLVM (an `llvm` library package), `vendor = true`. cargo.nu and maturin take `buildPkgs.rust`,
`libgcc-shim` stays for `rust-bootstrap` only. The pin follows `rust` one release behind.

**Python beyond the build stack**, with the first application: no generated library set. Named
packages are the interpreter, the build stack, native extensions that must link our libraries,
and the few pure libraries C projects import at build time. Applications bring `uv.lock` and
`fetch.pythonDeps { source }` is a dynamic derivation like cargoVendor.

**Seed 3** (building): LLVM 23.1.1 from our own pin with LoongArch and PowerPC backends.
Then: loongarch64 and powerpc64le cross platforms verified (platform entries,
builtins lists, qemu targets, rust-std, GOARCH are in); aarch64 seed uploaded. Later the seed is
built from this set's own musl-static packages instead of nixpkgs `pkgsStatic`, fixed point in CI.

**Windows cross (x86_64/aarch64-w64-mingw32).** All-LLVM like Linux: mingw-w64 headers + CRT
as the libc recipes, compiler-rt/runtimes/cc as in stage1, `lld` for PE. A `mingw` libc flavour
in platforms.nix without interp/RUNPATH (finish/launchers treat non-ELF as done; DLLs beside the
exe are already relocatable), `.exe` naming in install steps, `wine` as platform.emulator,
`x86_64-pc-windows-gnu`/`GOOS=windows` in cargo.nu/go.nu. No MSVC ABI (needs the unfree SDK).

**FreeBSD / NetBSD cross.** ELF and clang-native upstream, so the Linux machinery carries over:
`<cpu>-unknown-freebsd14` / `-netbsd10` triples, interp `/libexec/ld-elf.so.1` /
`/usr/libexec/ld.elf_so`, crt_interp + `$ORIGIN` + launchers unchanged, compiler-rt/runtimes with
an `os` switch instead of `linuxHeaders`. libc first as the release's `base.txz` (one hash-pinned
source per release), later built from `src.txz` (`lib/libc`, `csu`, `libthr`, `libm`). GOOS and
rust-std exist upstream. No user-mode emulator: untested builds, or a qemu-system VM job in CI.

**macOS cross (aarch64/x86_64-apple-darwin), SDK from source.** No Xcode: an `apple-sdk` recipe
assembles libSystem headers from Apple's open-source releases (xnu, Libc, libpthread,
libdispatch, Libinfo, libmalloc, libplatform, dyld, CommonCrypto, objc4, ... pinned per macOS
release, trackable by uptrack) plus committed `.tbd` link stubs, CoreFoundation from
swift-corelibs; closed frameworks stay out of scope. Toolchain is ours: clang, `ld64.lld`
(`--adhoc_codesign`), compiler-rt, libc++/libunwind for `arm64-apple-macos11`. Relocatability
maps to `@executable_path/../lib` install names instead of RUNPATH, fixup via
`llvm-install-name-tool`; no launcher. No emulator, so cross builds are untested.

**More language ecosystems**, each an interpreter package plus a build system in the shape of
the existing ones (named native packages, applications lock their own dependency graph, one
dynamic-derivation producer reading the upstream lock file, hashes upstream lacks in `locks/`):

- *Lua / LuaJIT.* `lua` (5.4, plain make, `LUA_ROOT` relative to the binary via launcher env) and
  `luajit` (its own Makefile, `HOST_CC=cc-build` + `CROSS=` for cross, `TARGET_SYS`; DynASM runs
  on the build machine so bitness must match: fine, all platforms are 64-bit). Build system
  `luarocks`: `uses = ["luarocks"]` builds a rockspec against our lua with `LUA_INCDIR/LIBDIR`
  from the dependency, C modules through jig; `fetch.luaRocks { source }` reads a committed
  `luarocks.lock` (rock name → version) and takes sha256 from `locks/luarocks.toml` since the
  manifest has none. cpath/path assembled per application as a launcher env, no global tree.
- *Ruby.* `ruby` (autotools; cross needs `--with-baseruby=` = `buildPkgs.ruby` and a few
  `ac_cv_func_*` already in config.site), `libyaml`/`libffi`/`openssl`/`zlib`/`readline` as
  dependencies. Build system `bundler`: `fetch.gems { source }` reads `Gemfile.lock` with its `CHECKSUMS`
  section (sha256, Bundler >= 2.6). Gems and library-style tools (asciidoctor) commit no lockfile,
  so `uptrack lock` generates one next to package.nix with `bundle lock --add-checksums`;
  applications that commit one mostly carry the section already (rails, gitlab, discourse), and
  for the rest (mastodon) `uptrack lock` adds the checksums to a copy. No `locks/` table needed. `bundle config set --local deployment/path`, `bundle install --local`
  from the vendored cache, native extensions compile through jig (`gem` honours CC/CFLAGS via
  rbconfig, which we rewrite for cross like sysconfigdata). `GEM_HOME`/`BUNDLE_GEMFILE` in the
  launcher env.
- *JS lockfiles beyond npm.* fetch-npm.nu splits into a shared registry-tarball layer (fetchurl
  by the lock's SRI, dedupe by URL, already there) and one reader per format: `pnpm-lock.yaml` v9
  (`from yaml`, `resolution.integrity`; output a content-addressed store dir for `pnpm install
  --offline --frozen-lockfile`), `yarn.lock` v1 (small text parser, `resolved` + `integrity`;
  output a yarn-offline-mirror dir), `bun.lock` (below). Yarn berry is deferred: its `checksum`
  is over the zip yarn repacks, not the registry tarball, so it cannot fix a fetch.
- *Bun.* `bun` itself is `prebuilt` first (upstream static-ish binaries for x86_64/aarch64
  linux, launcher via crt_interp like `rust`), from source later (zig + our LLVM/clang, large).
  Build system `bun`: `fetch.bunDeps { source }` reads `bun.lock` (text JSONC since 1.2, carries
  sha512 integrity like package-lock, so no `locks/` table), lays out the same cache tree
  `bun install --frozen-lockfile --offline` expects (`$BUN_INSTALL_CACHE_DIR`), then `bun build
  --compile` or a launcher running `bun run`. Shares tarball fetching with fetch-npm.nu.

**Reproducibility check.** A `repro-check` job that rebuilds the set without the cache socket
(`--rebuild`) and reports CA path mismatches; diffoscope only on those.

**uptrack.** `pythonDeps` locks (uv.lock → locks/pypi.toml where wheels lack hashes), reports, `sync-github`.

**CI.** buildbot-nix/nixbot on the two build platforms plus riscv64 cross, harmonia cache with
realisations.

## Follow-ups

- jig: teach the shapes that still show as `plain-link`/`plain-compile` (finish.nu prints
  samples: libtool relinks, `@rsp`, multi-source lines); rustc mode can cache bin/proc-macro
  crates now that links are cached; rustc keys should not change when only the vendor store path
  does; recurring `miss-fail` on identical rebuilds means an unstable conftest key.
- jig hashes link inputs serially; thread it if llvm-sized links show up in profiles.
- m4's gnulib `test-posix_spawn-chdir` spins in the sandbox: check crt_interp's AT_EXECFN
  fallback when cwd changes.
- nodejs, glib, qemu: first builds in flight; cross builds (riscv64, aarch64) to re-verify after
  the unpack-once change.
