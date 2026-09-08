# Emptying standins.nix

`standins.nix` is the one `import <nixpkgs>`. Tools it provides are replaced by ordinary
packages taken from `buildPkgs`, in waves ordered by what each tool needs to build. What is
left today: `go nodejs qemu-user cacert`.

## Done

**0. Sources.** `nix/fetch.nix`: `url`/`github` over `<nix/fetchurl.nix>`, `empty`, `goModules`
(FOD), and `cargoVendor`/`npmDeps` as dynamic derivations: a producer reads the lock file inside
the source, emits one `builtin:fetchurl` per crate/tarball plus a collector, via our own
worker-protocol client (`jig nix-store`). No vendor hashes anywhere. Needs `ca-derivations
dynamic-derivations` on the daemon.

**1. Seed tools.** dash, make, gawk, sed, grep, m4, bison and a minimal python ship in the seed
(bison+m4 because glibc ships only `intl/plural.y`). stage0 is only the musl toolchain + jig.
`bootstrap/` imports nothing from nixpkgs.

**2. Base userland.** sed grep gawk diffutils findutils patch gnumake m4 gperf pkgconf coreutils
bison flex bash perl as packages. They set `bootstrapTools = true` and build with the seed's static
tools. Everything else gets them as `baseTools.full`. No texinfo/help2man. perl is
`-Duserelocatableinc`. Side effects: shebang rewrite no longer touches mtimes, grep drops
egrep/fgrep, `tests.version` (default on) and `tests.relocated` (opt-in) added to finish.

**3+4. Build systems.** ninja (compiled from a file list, since configure.py would close a
python→zlib→cmake→ninja cycle), cmake (`./bootstrap`, bundled libs for the same reason),
python-{flit-core,installer,packaging,pyproject-hooks,build,setuptools}, meson.
`build-systems.nix` takes tools from `buildPkgs`. The python stack is ordered and a member only
sees its predecessors. `python.nu` lets backends build themselves and gives entry-point scripts
a `sys.path` line relative to `__file__`. `launch` became its own static-pie store path
(`pkgs/la/launch/src/launch.cc`, `pkgs/la/launch/bootstrap.nu`). sysroot.nu no longer corrupts `libc.a`.

**5. Rust (binary).** `rust` = upstream's rustc + cargo + rust-std tarballs, unmodified, marked `prebuilt`:
bin/ entries become launch records that run the foreign ELF under our `ld.so --argv0 bin/foo
--library-path <sysroot:deps>`, no patchelf. `libgcc-shim` provides the versioned
`libgcc_s.so.1` (libunwind + the few libgcc integer routines) such binaries import. cargo.nu
passes `-Clinker-features=-lld` so linking stays with our cc. maturin is an ordinary cargo package
(no default features). jig keys tools by resolved store
path (`Store::ToolId`), since hash-masking made two rustc versions share cache entries.

## Next

**5b. Rust from source.** Today's `rust` (upstream binaries, `prebuilt`) becomes
`rust-bootstrap`, used only as `buildDependencies` of `rust`: rustc + cargo built from the
rustc-src tarball with `x.py` against our LLVM (`llvm-config` from a `pkgs/llvm` library
package), libc and cc, `vendor = true` so no network. cargo.nu and maturin then take
`buildPkgs.rust`; `libgcc-shim` stays only for `rust-bootstrap`. Same shape as nixpkgs
(binary N-1 builds N), and the pin in `rust-bootstrap/sources.toml` follows `rust` one release
behind.

**6. Go.** `go-bootstrap` (upstream static tarball, `prebuilt`), `go` built from source with it. `fetch.goModules` and
go.nu switch.

**7. Node.** nodejs from source (C++, python, ninja, bundled deps first). Only npm.nu needs it.

**8. qemu-user.** glib (meson) then qemu `--static --target-list=…-linux-user`. `default.nix
emulator` switches. cacert: curl's `mk-ca-bundle.pl` with our perl.

**Python beyond the stack** (with the first application, not before): no generated library set.
Named packages are the interpreter, the build stack (extend on demand), native extensions that
must link our libraries, and the few pure libraries C projects import at build time (jinja2,
mako, pyyaml…). `python.nu` reads `build-backend` itself. Applications bring `uv.lock`, and
`fetch.pythonDeps { source }` is a dynamic derivation like cargoVendor that prefers set packages
for natives. Its marker/wheel-tag logic is tested against pyproject.nix fetched in the test.

**Updater.** See docs/uptrack.md. Done: datasources, check/apply/verify, `update.nu` hooks, tree
on `sources.toml`. Next: lock generation for `fetch.*Deps` packages, reports/`sync-github`.

## Follow-ups

- rustc cache keys change when only the vendor store path changes (fd: `rs-miss-stored=57`).
  Make source inputs content-keyed.
- glibc shows `plain-compile=473`: find what jig treats as uncacheable there.
- m4's gnulib `test-posix_spawn-chdir` spins in the sandbox: check the crt_interp AT_EXECFN
  fallback when cwd changes.
- Seed: build it from this set's own packages for a musl-static platform instead of nixpkgs
  pkgsStatic. Size levers: nu without polars/sqlite, LLVM with three targets.

## End state

No `<nixpkgs>` anywhere. Pinned binaries: our LLVM+nu seed, upstream rust-bootstrap and go-bootstrap (each only a build
input of the from-source package).
Verification per wave: build every package natively, zlib/jq/fd for riscv64, cache hit rate
unchanged on a second run.
