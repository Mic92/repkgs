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
