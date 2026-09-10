# Build-tree state shared across builds through jigd under a key over its inputs: configure-time
# probe results (config.cache, cmake's initial cache), and whole tool cache directories for
# compilers jig cannot sit in front of (zig).

use core.nu *

# key = kind + every explicit input of the probes: the script that defines them, the masked
# toolchain/dependency/tool set, platform, flags. $out is the fixed CA placeholder, so stable
export def key [kind: string, scripts: list<path>]: nothing -> string {
  let c = (ctx)
  let roots = ($env.JIG_STORE_ROOTS | split row " " | each { path basename | str substring 33.. } | sort)
  let id = ({
    kind: $kind
    script: ($scripts | sort | each { open --raw $in | hash sha256 })
    triple: $c.platform.triple
    roots: $roots
    out: $c.out
    flags: [$env.CFLAGS? $env.CXXFLAGS? $env.CPPFLAGS? $env.LDFLAGS? $env.PKG_CONFIG_PATH?]
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

# a directory as one zstd tarball under `key`. true when restored
export def restore-dir [key: string, dir: path]: nothing -> bool {
  let c = (ctx)
  let tar = $"($c.build)/(($key | str replace -a '/' '_')).tar.zst"
  if not ($c.cache and (^jig cache get $key $tar | complete).exit_code == 0) { return false }
  mkdir $dir
  ^bsdtar -xf $tar -C $dir
  rm $tar
  true
}

export def store-dir [key: string, dir: path]: nothing -> nothing {
  let c = (ctx)
  if not ($c.cache and ($dir | path exists)) { return }
  let tar = $"($c.build)/(($key | str replace -a '/' '_')).tar.zst"
  ^bsdtar -c --zstd -f $tar -C $dir .
  note cache $"($key | split row / | first 2 | str join /): stored (ls $tar | get 0.size)"
  ^jig cache put $key $tar | complete | ignore
  rm $tar
}
