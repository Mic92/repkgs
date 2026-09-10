# configure-time probe results (autotools config.cache, cmake's initial cache) shared across
# builds through jigd, so a package's second build skips the hundreds of compiler probes.

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
