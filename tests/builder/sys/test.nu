# builder/sys-libs.nu over the lock files next to this script
use sys-libs.nu
use checks.nu *

let dir = $env.fixtures
assert "wanted: union over Cargo.lock, go.sum, Gemfile.lock" ((sys-libs wanted $dir) == [libyaml openssl sqlite])
sys-libs check $dir [libyaml openssl sqlite]
sys-libs check $dir null
fails "check: stale pin" { sys-libs check $dir [openssl] }
let deps = [{name: openssl, root: "/o"} {name: sqlite, root: "/s"} {name: zlib, root: "/z"}]
assert "env-for cargo" ((sys-libs env-for cargo $deps | get OPENSSL_DIR) == "/o")
assert "env-for: only libraries present" ("LIBZ_SYS_STATIC" in (sys-libs env-for cargo $deps | columns))
assert "go-tags" ((sys-libs go-tags $deps) == [libsqlite3])
assert "gem-build-flags" ((sys-libs gem-build-flags [{name: libyaml, root: "/y"}]) == {psych: "--with-libyaml-dir=/y"})
done
