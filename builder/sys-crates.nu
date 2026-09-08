# -sys crates -> the package of ours that provides the C library, and the env that makes the crate
# link it instead of building a bundled copy or probing in its own way (`{root}` = that package's
# store path). fetch-cargo.nu selects libraries from `fetch.cargoVendor`'s `sysLibs` by the crate
# names in Cargo.lock; cargo.nu sets the env for every dependency that is present. Explicit on
# purpose: adding a library is a decision. Crates that only ever vendor (aws-lc-sys, ring,
# libmimalloc-sys, …) or are raw OS bindings (linux-raw-sys, …) have no entry.
export const SYS_CRATES = {
  "openssl-sys": {pkg: openssl, env: {OPENSSL_NO_VENDOR: "1", OPENSSL_DIR: "{root}", OPENSSL_LIB_DIR: "{root}/lib", OPENSSL_INCLUDE_DIR: "{root}/include"}}
  "libz-sys": {pkg: zlib, env: {LIBZ_SYS_STATIC: "0", ZLIB_NO_VENDOR: "1"}}
  "libz-ng-sys": {pkg: zlib, env: {}}
  "zstd-sys": {pkg: zstd, env: {ZSTD_SYS_USE_PKG_CONFIG: "1"}}
  "bzip2-sys": {pkg: bzip2, env: {BZIP2_SYS_USE_PKG_CONFIG: "1"}}
  "lzma-sys": {pkg: xz, env: {LZMA_API_STATIC: "0"}}
  "liblzma-sys": {pkg: xz, env: {LZMA_API_STATIC: "0"}}
  "libsqlite3-sys": {pkg: sqlite, env: {LIBSQLITE3_SYS_USE_PKG_CONFIG: "1"}}
  "curl-sys": {pkg: curl, env: {LIBCURL_NO_VENDOR: "1"}}
  "libgit2-sys": {pkg: libgit2, env: {LIBGIT2_NO_VENDOR: "1"}}
  "libssh2-sys": {pkg: libssh2, env: {LIBSSH2_SYS_USE_PKG_CONFIG: "1"}}
  "libnghttp2-sys": {pkg: nghttp2, env: {}}
  "pcre2-sys": {pkg: pcre2, env: {PCRE2_SYS_STATIC: "0"}}
  "onig_sys": {pkg: oniguruma, env: {RUSTONIG_SYSTEM_LIBONIG: "1", RUSTONIG_DYNAMIC_LIBONIG: "1"}}
  "lz4-sys": {pkg: lz4, env: {}}
  "libsodium-sys": {pkg: libsodium, env: {SODIUM_USE_PKG_CONFIG: "1"}}
  "freetype-sys": {pkg: freetype, env: {FREETYPE_SYS_USE_PKG_CONFIG: "1"}}
  "yeslogic-fontconfig-sys": {pkg: fontconfig, env: {}}
  "expat-sys": {pkg: expat, env: {}}
  "libffi-sys": {pkg: libffi, env: {LIBFFI_SYS_USE_PKG_CONFIG: "1"}}
  "libdbus-sys": {pkg: dbus, env: {DBUS_SYS_USE_PKG_CONFIG: "1"}}
  "libxml": {pkg: libxml2, env: {}}
  "tikv-jemalloc-sys": {pkg: jemalloc, env: {JEMALLOC_OVERRIDE: "{root}/lib/libjemalloc.so"}}
  "clang-sys": {pkg: libclang, env: {LIBCLANG_PATH: "{root}/lib"}}
}

# library package names the crates in this lock want
export def wanted [crate_names: list<string>]: nothing -> list<string> {
  $crate_names | each {|n| $SYS_CRATES | get -o $n | get -o pkg } | compact | uniq | sort
}

# env for the dependencies (records with name, root) that some entry names
export def env-for [deps: list<record>]: nothing -> record {
  let by_pkg = ($SYS_CRATES | values | group-by pkg)
  $deps | each {|d|
    $by_pkg | get -o $d.name | default [] | each {|e| $e.env | items {|k, v| {k: $k, v: ($v | str replace -a "{root}" $d.root)} } }
  } | flatten | flatten | reduce --fold {} {|it, acc| $acc | upsert $it.k $it.v }
}
