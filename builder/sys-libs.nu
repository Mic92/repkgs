# Locked third-party packages that link a C library, per ecosystem: which package of ours provides
# it (`pkg`) and how the build is told to use it instead of a bundled copy (`env`, plus `tags` for
# go and `flags` for bundler; `{root}` stands for the library's store path).
#
# default.nix offers the producers every `pkg:` below that exists as a package; a producer `pick`s the
# ones its lock file names and propagates them through its output's exports.json, so the package
# build has them as dependencies without package.nix listing them. The build-system module then
# applies `env-for`/`go-tags`/`gem-build-flags` for whatever libraries are present.
#
# Explicit on purpose: linking a system library is a decision. Packages that only ever vendor
# (ring, aws-lc-sys, modernc.org/sqlite) or are plain OS bindings have no entry.
export const TABLES = {
  # Cargo.lock package names
  cargo: {
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
  # go.sum module paths (cgo packages)
  go: {
    "github.com/mattn/go-sqlite3": {pkg: sqlite, env: {}, tags: [libsqlite3]}
    "github.com/deluan/go-taglib": {pkg: taglib, env: {}}
    "go.senan.xyz/taglib": {pkg: taglib, env: {}}
    "github.com/google/gopacket": {pkg: libpcap, env: {}}
    "github.com/davidbyttow/govips/v2": {pkg: vips, env: {}}
    "gopkg.in/gographics/imagick.v3": {pkg: imagemagick, env: {}}
    "github.com/linxGnu/grocksdb": {pkg: rocksdb, env: {}}
    "github.com/containers/gpgme": {pkg: gpgme, env: {}}
    "github.com/seccomp/libseccomp-golang": {pkg: libseccomp, env: {}}
    "github.com/coreos/go-systemd/v22": {pkg: systemd, env: {}}
  }
  # uv.lock / PyPI names: these build from sdist so they link our library instead of a wheel's bundled copy
  python: {
    psycopg2: {pkg: libpq, env: {}}
    "psycopg-c": {pkg: libpq, env: {}}
    lxml: {pkg: libxml2, env: {}}
    pyyaml: {pkg: libyaml, env: {PYYAML_FORCE_LIBYAML: "1"}}
    "mysqlclient": {pkg: mariadb-connector-c, env: {}}
    pycairo: {pkg: cairo, env: {}}
    pygobject: {pkg: glib, env: {}}
    "dbus-python": {pkg: dbus, env: {}}
    pyzmq: {pkg: zeromq, env: {PYZMQ_NO_BUNDLE: "1"}}
    "python-ldap": {pkg: openldap, env: {}}
    pycurl: {pkg: curl, env: {PYCURL_SSL_LIBRARY: openssl}}
    h5py: {pkg: hdf5, env: {HDF5_DIR: "{root}"}}
  }
  # Gemfile.lock gem names; `flags` become `bundle config build.<gem>` (extconf.rb arguments)
  gems: {
    psych: {pkg: libyaml, env: {}, flags: ["--with-libyaml-dir={root}"]}
    nokogiri: {pkg: libxml2, env: {NOKOGIRI_USE_SYSTEM_LIBRARIES: "1"}, flags: ["--use-system-libraries"]}
    sqlite3: {pkg: sqlite, env: {}, flags: ["--enable-system-libraries" "--with-sqlite3-dir={root}"]}
    pg: {pkg: libpq, env: {}, flags: ["--with-pg-dir={root}"]}
    mysql2: {pkg: mariadb-connector-c, env: {}, flags: ["--with-mysql-dir={root}"]}
    ffi: {pkg: libffi, env: {}, flags: ["--enable-system-libffi"]}
    openssl: {pkg: openssl, env: {}, flags: ["--with-openssl-dir={root}"]}
    zlib: {pkg: zlib, env: {}, flags: ["--with-zlib-dir={root}"]}
    rugged: {pkg: libgit2, env: {}, flags: ["--use-system-libraries"]}
    re2: {pkg: re2, env: {}, flags: ["--enable-system-libraries"]}
    hiredis: {pkg: hiredis, env: {}, flags: ["--with-system-hiredis"]}
    rmagick: {pkg: imagemagick, env: {}, flags: []}
    "ruby-vips": {pkg: vips, env: {}, flags: []}
    curses: {pkg: ncurses, env: {}, flags: []}
    "idn-ruby": {pkg: libidn, env: {}, flags: ["--with-idn-dir={root}"]}
    "charlock_holmes": {pkg: icu, env: {}, flags: ["--with-icu-dir={root}"]}
    gpgme: {pkg: gpgme, env: {RUBY_GPGME_USE_SYSTEM_LIBRARIES: "1"}, flags: ["--use-system-libraries"]}
  }
}

# --- producer side (fetch/*.nu): which of the offered libraries does this lock want ----------------

# `sys_libs_file` is nix/fetch.nix's {name: {drv, out}}; `locked` the package names in the lock.
# Returns [{name, drv, out}] for every library some locked package maps to; names the set does
# not provide are reported (that dependency will then vendor its copy or fail to build)
export def pick [ecosystem: string, locked: list<string>, sys_libs_file: path]: nothing -> table {
  let offered = (open $sys_libs_file)
  let table = ($TABLES | get $ecosystem)
  let wanted = ($table | transpose locked entry | where locked in $locked | get entry.pkg | uniq | sort)
  let missing = ($wanted | where $it not-in $offered)
  if ($missing | is-not-empty) { print -e $"sys-libs: ($missing | str join ', ') wanted by the lock but not in sysLibs" }
  let picked = ($wanted | where $it in $offered | each {|name| {name: $name} | merge ($offered | get $name) })
  if ($picked | is-not-empty) { print -e $"sys-libs: ($picked | get name | str join ' ')" }
  $picked
}

# the exports.json of a producer output: nothing to link itself, the picked libraries propagate
export def exports [name: string, picked: list<record<name: string, drv: string, out: string>>]: nothing -> record {
  {name: $name, includeDirs: [], libDirs: [], libs: [], pkgconfigDirs: [], aclocalDirs: [], propagate: ($picked | get -o out | default [])}
}

# python packages that build from sdist whenever they appear (fetch-pypi.nu)
export def sdist-packages []: nothing -> list<string> { $TABLES.python | columns }

# --- builder side (cargo.nu, go.nu, bundler.nu, pyapp.nu): configure for the libraries present ----

# table entries of `ecosystem` whose library is among `deps` ({name, root, …} records from ctx),
# each with that dependency's root attached
def active [ecosystem: string, deps: list<record<name: string, root: string>>]: nothing -> table {
  let roots = ($deps | select name root | rename pkg root)
  $TABLES | get $ecosystem | transpose locked entry | flatten entry | join $roots pkg
}

# env vars from the matching entries, {root} replaced by the library's store path
export def env-for [ecosystem: string, deps: list<record<name: string, root: string>>]: nothing -> record {
  active $ecosystem $deps
    | reduce --fold {} {|e, acc| $acc | merge ($e.env | items {|k, v| [$k ($v | str replace -a "{root}" $e.root)] } | into record) }
}

# go: build tags that switch a module to the system library
export def go-tags [deps: list<record<name: string, root: string>>]: nothing -> list<string> {
  active go $deps | each { $in.tags? | default [] } | flatten | uniq
}

# bundler: gem -> `bundle config build.<gem>` argument string
export def gem-build-flags [deps: list<record<name: string, root: string>>]: nothing -> record {
  active gems $deps | where { $in.flags | is-not-empty }
    | reduce --fold {} {|e, acc| $acc | upsert $e.locked ($e.flags | str replace -a "{root}" $e.root | str join " ") }
}
