# Build-tree state shared across builds through jigd under a key over its inputs: configure-time
# probe results (config.cache, cmake's initial cache), and whole tool cache directories for
# compilers jig cannot sit in front of (zig).

use core.nu *

# key = kind + every input of the probes. Roots go in as full store paths: content-addressed,
# so equal content is an equal path, and probe results name them (lt_cv_path_LD)
export def key [kind: string, scripts: list<path>, --no-out]: nothing -> string {
  let c = (ctx)
  let id = ({
    kind: $kind
    script: ($scripts | sort | each { open --raw $in | hash sha256 })
    target: $c.platform.clangTarget
    roots: $c.roots
    out: (if $no_out { null } else { $c.out })
    flags: [($env.PKGS_CC | from json | values) $env.PKG_CONFIG_PATH?]
  } | to json -r | hash sha256)
  $"probe3/($kind)/($id)"
}

# restore a build system's probe results (config.cache, cmake -C init) from the cache daemon
export def restore [key: string, file: path]: nothing -> bool {
  (ctx).cache and (^jig cache get $key $file | complete).exit_code == 0
}

# store them for the next build with the same key. Best effort: a daemon gone is no error
export def store [key: string, file: path]: nothing -> nothing {
  if not ((ctx).cache and ($file | path exists)) { return }
  if (^jig cache put $key $file | complete).exit_code != 0 { note probe-cache $"put ($key) failed" }
}

# a directory tree under `key`: file contents deduplicated in jigd, one listing per key
export def restore-dir [key: string, dir: path]: nothing -> bool {
  (ctx).cache and (^jig cache get-dir $key $dir | complete).exit_code == 0
}

export def store-dir [key: string, dir: path]: nothing -> nothing {
  if (ctx).cache and ($dir | path exists) { ^jig cache put-dir $key $dir }
}
