# The time zone database is the machine's: libc reads /usr/share/zoneinfo, then /etc/zoneinfo
# (NixOS), never its own prefix (pkgs/gl/glibc/glibc-tzdir-etc-zoneinfo.patch). The sandbox has
# neither, so check the paths compiled into the libc the binary loads, and one real lookup via TZDIR
use checks.nu *
use glob.nu [files]

let tz = $"($env.pkg)/bin/tz"
# the sandbox only holds the closure, so the one libc.so.6 in the store is the binary's
let libc = (files /nix/store/*-sysroot-*/lib/libc.so.6 | first)
let dirs = (open --raw $libc | decode utf-8 | split row "\u{0}" | where { $in =~ zoneinfo })
assert $"zoneinfo directories are the system's: ($dirs)" (($dirs | sort) == ["/etc/zoneinfo/%s" "/usr/share/zoneinfo"])
assert "reads a zone file" ((with-env {TZDIR: $"($env.fixtures)/zoneinfo", TZ: "Test/Zone"} { ^$tz }) == "TST")
done
