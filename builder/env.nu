# The process environment every build step inherits. Each function returns a record, `main`
# loads them in order: sandbox dirs, reproducibility pins, the toolchain's view of the
# dependencies, default flags, then the dependencies' and the spec's own `env` on top.
use core.nu *

# writable HOME and XDG dirs for tools with per-user caches (npm, pnpm, bun, luarocks, gem),
# TMPDIR inside the build, CI=true so nothing prompts or draws progress bars
def sandbox-dirs [a: record, out: string]: nothing -> record {
  let home = $"($env.NIX_BUILD_TOP)/home"
  mkdir $home
  {PATH: ($a.buildDependencies | each { $"($in)/bin" }), HOME: $home, XDG_CACHE_HOME: $"($home)/.cache"
    XDG_DATA_HOME: $"($home)/.local/share", XDG_CONFIG_HOME: $"($home)/.config", TMPDIR: $env.NIX_BUILD_TOP
    CI: "true", out: $out}
}

# no wall clock, locale, timezone or hash randomisation in outputs. 1980-01-01 is the earliest
# mtime ZIP archives (wheels, jars) can store. clang derives __DATE__ from SOURCE_DATE_EPOCH
def reproducible [a: record]: nothing -> record {
  {SOURCE_DATE_EPOCH: "315532800", TZ: "UTC", LC_ALL: "C.UTF-8", ZERO_AR_DATE: "1", PERL_HASH_SEED: "0"
    PYTHONHASHSEED: "0", KBUILD_BUILD_TIMESTAMP: "@315532800", KBUILD_BUILD_USER: "pkgs", KBUILD_BUILD_HOST: "pkgs"
    CONFIG_SITE: $a.CONFIG_SITE}
}

# every store dir this build reads from: the dependency closure (lock trees included), build
# tools, and what the toolchain lists in its etc/roots (sysroot, seed headers). jig maps masked
# manifest paths back to files through exactly this list
def store-roots [a: record, deps: list<record>]: nothing -> list<string> {
  ($deps | get root) ++ $a.buildDependencies ++ (which cc | each {|c| open --raw ($c.path | path dirname -n 2 | path join etc/roots) | split row " " } | flatten | compact -e) | uniq
}

# how compilers and build systems find the dependencies, and what jig needs for its cache keys:
# content identity (a rebuilt but identical dependency still hits), the store roots masked
# header names map back to, and a prefix map so no build or store path lands in DWARF/__FILE__
def toolchain [a: record, deps: list<record>]: nothing -> record {
  let mask = {|p: string, under: string| $"($p)=/($under)/($p | path basename | str substring 33..)" }
  {
    CC: cc, CXX: c++, AR: llvm-ar, RANLIB: llvm-ranlib, NM: llvm-nm, STRIP: llvm-strip
    CPPFLAGS: (dep-dirs $deps includeDirs | each { $"-I($in)" } | str join " ")
    LDFLAGS: (dep-dirs $deps libDirs | each { $"-L($in)" } | str join " ")
    PKG_CONFIG_PATH: (dep-dirs $deps pkgconfigDirs | str join ":")
    CMAKE_PREFIX_PATH: ($deps | get root | str join ";")
    ACLOCAL_PATH: (dep-dirs $deps aclocalDirs | str join ":")
    JIG_LOG: $"($env.NIX_BUILD_TOP)/jig.log"
    JIG_LOG_ARGS: $"($env.NIX_BUILD_TOP)/jig-uncached.log"
    JIG_STORE_IDENTITY: content
    JIG_STORE_ROOTS: (store-roots $a $deps | str join " ")
    PKGS_PREFIX_MAP: ([$"($env.NIX_BUILD_TOP)=/build"] ++ ($deps | get root | each { do $mask $in deps }) ++ ($a.buildDependencies | each { do $mask $in tools }) | str join ":")
  }
}

# by name so a package turns one off with `cc.hardening.fortify = false` (names as in nixpkgs).
# -march and the platform's CET/BTI flag are toolchain facts and live in the cc config instead
const HARDENING = {
  fortify: ["-D_FORTIFY_SOURCE=3"]
  stackprotector: ["-fstack-protector-strong"]
  stackclashprotection: ["-fstack-clash-protection"]
  trivialautovarinit: ["-ftrivial-auto-var-init=zero"]
  format: ["-Wformat" "-Wformat-security" "-Werror=format-security"]
  strictoverflow: ["-fwrapv"]
  strictflexarrays: ["-fstrict-flex-arrays=1"]
  zerocallusedregs: ["-fzero-call-used-regs=used-gpr"]
  libcxxhardening: ["-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST"]
  relro: ["-Wl,-z,relro"]
  bindnow: ["-Wl,-z,now"]
}

# per-package compiler defaults (design.md "Builders"): profiling-friendly and hardened, plus the
# package's `cc.{cflags,cxxflags,ldflags}`. Not CFLAGS: jig injects them itself ($PKGS_CC, keyed
# by toolchain root), so a Makefile that sets CFLAGS cannot drop them and cc-build in a cross
# build compiles host helpers without target flags
def package-cc [a: record]: nothing -> record {
  let cc = ($a.spec.cc? | default {})
  let keep = (if $cc.hardening? == false { {} } else { $HARDENING | merge ($cc.hardening? | default {}) })
  let on = {|k| ($keep | get -o $k | default false) != false }
  let h = ($HARDENING | reject libcxxhardening relro bindnow | items {|k, v| if (do $on $k) { $v } } | compact | flatten)
  let flags = {
    cflags: (["-O2" "-g" "-fno-omit-frame-pointer" "-mno-omit-leaf-frame-pointer"] ++ $h ++ ($cc.cflags? | default []))
    cxxflags: ((if (do $on libcxxhardening) { $HARDENING.libcxxhardening } else { [] }) ++ ($cc.cxxflags? | default []))
    ldflags: (([relro bindnow] | each {|k| if (do $on $k) { $HARDENING | get $k } } | compact | flatten) ++ ["-Wl,-z,noexecstack" "-Wl,--as-needed"] ++ ($cc.ldflags? | default []))
  }
  let root = (which cc | get 0.path | path expand | path dirname -n 2)
  {PKGS_CC: ({} | insert $root $flags | to json -r)}
}

# rustc and go go through jig only when the environment says so, and more than their own build
# system runs them (maturin from pyapp, cargo from napi-rs npm packages, `go build` from
# Makefiles), so this is decided here for every build. RUSTC is absolute so the cache key names
# the toolchain. Incremental artefacts are not cacheable
export def compiler-caches []: nothing -> record {
  let rust = (if (which rustc | is-not-empty) { {RUSTC: (which rustc | first | get path), RUSTC_WRAPPER: (which rustcwrap | first | get path), CARGO_INCREMENTAL: "0"} } else { {} })
  let go = (if (which go | is-not-empty) { {GOCACHEPROG: (which gocacheprog | first | get path)} } else { {} })
  $rust | merge $go
}

export def --env main [a: record, deps: list<record>, out: string]: nothing -> nothing {
  load-env (sandbox-dirs $a $out)
  load-env (reproducible $a)
  load-env (toolchain $a $deps)
  load-env (package-cc $a)
  load-env ($deps | get env | reduce -f {} {|it, acc| $acc | merge $it })
  load-env ($a.spec.env? | default {})
}
