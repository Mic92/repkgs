# what every subcommand shares: where the set is, how nix is called, where the cache socket is
export const INSIDE = "/nix/var/nix/jigd/socket"
# what the set needs from nix, whatever nix.conf says
export const XP = [--extra-experimental-features "nix-command ca-derivations dynamic-derivations"]

const ROOT = path self ../..
export def root []: nothing -> string { $ROOT }

# --for as nix sees it: on a command line, and inside an expression
export def platform-arg [p]: nothing -> list<string> { if $p == null { [] } else { [--argstr platform $p] } }
export def set-expr [p]: nothing -> string { $"\(import (root) (if $p == null { "{ }" } else { $"{ platform = \"($p)\"; }" })\)" }

export def fail [msg: string]: nothing -> error { error make --unspanned {msg: $msg} }

# one nix expression to JSON. Nix's own errors (unknown package or platform, a package.nix
# mistake) are its last `error:` line, not the trace through our query expression
export def eval [expr: string]: nothing -> any {
  let r = (^nix-instantiate ...$XP --eval --strict --json --expr $expr | complete)
  if $r.exit_code != 0 {
    fail ($r.stderr | lines | where $it =~ '^\s*error:' | last | default $r.stderr | str replace -r '^\s*error:\s*' "")
  }
  $r.stdout | from json
}

# the package <attr> of the set for platform p, as an expression. `s.${"7zip"}` parses where
# s.7zip does not, and a typo names its neighbours instead of nix's attribute trace
export def pkg-expr [attr: string, p]: nothing -> string {
  let n = ($attr | to json)
  $"\(let s = (set-expr $p); n = ($n); in s.${n} or \(builtins.throw \"no package ${n}, near: ${toString \(builtins.filter \(a: builtins.substring 0 2 a == builtins.substring 0 2 n\) \(builtins.attrNames s\)\)}\"\)\)"
}

# a socket file something is listening on (a crashed jigd leaves the file behind)
export def is-socket [p: string]: nothing -> bool {
  ($p | path exists) and (ls -D $p | get 0.type) == "socket" and (open --raw /proc/net/unix | str contains $" ($p | path expand)\n")
}

# under /tmp, not XDG_RUNTIME_DIR: the nix build user has to reach it through extra-sandbox-paths
export def jigd-dir []: nothing -> string { $"/tmp/jigd-(id -u)" }

export def jigd-socket []: nothing -> any {
  [$env.JIG_SOCK? $INSIDE $"(jigd-dir)/socket"] | compact | where {|p| is-socket $p } | get 0?
}

# maps the jigd socket into the sandbox (trusted user) and keeps the build local, a remote has no cache
export def cache-args []: nothing -> list<string> {
  let sock = (jigd-socket)
  if $sock == null {
    print -e "repkgs: no jigd socket, building uncached (repkgs cache start)"
    []
  } else {
    [--option extra-sandbox-paths $"($INSIDE)=($sock)" --builders ""]
  }
}

export def drv [attr: string, p]: nothing -> string { eval $"(pkg-expr $attr $p).drvPath" }

