# zig has no cache protocol jig could speak, only ZIG_GLOBAL_CACHE_DIR. Its manifests record
# paths relative to the lib dir, project root and cache root, so the directory is valid in the
# next sandbox: restored before cmake builds stage3, stored after. Keyed on the source tree and
# patches (store paths, so exact) plus what probe-cache keys on: platform, dependencies, flags
use ../../../builder/core.nu *
use ../../../builder/probe-cache.nu

def key []: nothing -> string {
  let a = (attrs)
  probe-cache key $"zig-cache/($a.src | path basename)" $a.patches
}

export def restore []: nothing -> nothing {
  note zig-cache (if (probe-cache restore-dir (key) $env.ZIG_GLOBAL_CACHE_DIR) { "restored" } else { "cold" })
}

export def store []: nothing -> nothing { probe-cache store-dir (key) $env.ZIG_GLOBAL_CACHE_DIR }
