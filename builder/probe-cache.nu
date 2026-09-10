# Build-tree state shared across builds through jigd under a key over its inputs: configure-time
# probe results (config.cache, cmake's initial cache), and whole tool cache directories for
# compilers jig cannot sit in front of (zig).

use core.nu *

# key = kind + every explicit input of the probes: the script that defines them, the masked
# toolchain/dependency/tool set, platform, flags. $out is the fixed CA placeholder, so stable
export def key [kind: string, scripts: list<path>]: nothing -> string {
  let c = (ctx)
  let roots = ($c.roots | each { path basename | str substring 33.. } | sort)
  let id = ({
    kind: $kind
    script: ($scripts | sort | each { open --raw $in | hash sha256 })
    triple: $c.platform.triple
    roots: $roots
    out: $c.out
    flags: [($env.PKGS_CC | from json | values) $env.PKG_CONFIG_PATH?]
  } | to json -r | hash sha256)
  $"probe/($kind)/($id)"
}

# restore a build system's probe results (config.cache, cmake -C init) from the cache daemon
export def restore [key: string, file: path]: nothing -> bool {
  (ctx).cache and (^jig cache get $key $file | complete).exit_code == 0
}

# store them for the next build with the same key
export def store [key: string, file: path]: nothing -> nothing {
  if (ctx).cache and ($file | path exists) { ^jig cache put $key $file | complete }
}

# a directory tree under `key`: file contents deduplicated in jigd, one listing per key
export def restore-dir [key: string, dir: path]: nothing -> bool {
  (ctx).cache and (^jig cache get-dir $key $dir | complete).exit_code == 0
}

export def store-dir [key: string, dir: path]: nothing -> nothing {
  if (ctx).cache and ($dir | path exists) { ^jig cache put-dir $key $dir }
}
