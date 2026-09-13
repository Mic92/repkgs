# Build-tree state shared across builds through jigd under a key over its inputs: configure-time
# probe results (config.cache, cmake's initial cache), and whole tool cache directories for
# compilers jig cannot sit in front of (zig).

use core.nu *

# key = kind + every explicit input of the probes: the script that defines them, the masked
# toolchain/dependency/tool set, platform, flags, and $out unless the tree records no prefix
export def key [kind: string, scripts: list<path>, --no-out]: nothing -> string {
  let c = (ctx)
  let roots = ($c.roots | each { path basename | str substring 33.. } | sort)
  let id = ({
    kind: $kind
    script: ($scripts | sort | each { open --raw $in | hash sha256 })
    triple: $c.platform.triple
    roots: $roots
    out: (if $no_out { null } else { $c.out })
    flags: [($env.PKGS_CC | from json | values) $env.PKG_CONFIG_PATH?]
  } | to json -r | hash sha256)
  $"probe2/($kind)/($id)"
}

# The key masks store hashes, so a hit can come from a build whose toolchain and dependencies
# had the same content under other paths. Probe results name those paths (lt_cv_path_LD): they
# are stored as {root0}, {root1}, ... in roots order and filled in with this build's on restore
def masked [--undo]: string -> string {
  let text = $in
  (ctx).roots | enumerate | reduce --fold $text {|r, t|
    if $undo { $t | str replace -a $"{root($r.index)}" $r.item } else { $t | str replace -a $r.item $"{root($r.index)}" }
  }
}

# restore a build system's probe results (config.cache, cmake -C init) from the cache daemon
export def restore [key: string, file: path]: nothing -> bool {
  if not ((ctx).cache and (^jig cache get $key $file | complete).exit_code == 0) { return false }
  open --raw $file | masked --undo | save -f $file
  true
}

# store them for the next build with the same key
export def store [key: string, file: path]: nothing -> nothing {
  if not ((ctx).cache and ($file | path exists)) { return }
  let tmp = $"($file).masked"
  open --raw $file | masked | save -f $tmp
  ^jig cache put $key $tmp | complete
  rm $tmp
}

# a directory tree under `key`: file contents deduplicated in jigd, one listing per key
export def restore-dir [key: string, dir: path]: nothing -> bool {
  (ctx).cache and (^jig cache get-dir $key $dir | complete).exit_code == 0
}

export def store-dir [key: string, dir: path]: nothing -> nothing {
  if (ctx).cache and ($dir | path exists) { ^jig cache put-dir $key $dir }
}
