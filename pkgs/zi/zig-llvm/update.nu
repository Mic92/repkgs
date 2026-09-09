# uptrack hook. The LLVM major is zig's choice: cmake/Findllvm.cmake of the pinned zig says
# "expected LLVM <N>.x", and only releases of that major are candidates.
use datasource.nu
use purl.nu *
use http.nu *

export def resolve [pkg: record]: nothing -> table {
  let zig = (open ($pkg.dir | path dirname | path join zig sources.toml)).pin.version
  let url = $"https://codeberg.org/ziglang/zig/raw/tag/($zig)/cmake/Findllvm.cmake"
  let r = (http cached $url --max-age 1day)
  if $r.status != 200 { error make {msg: $"GET ($url) → ($r.status)"} }
  let major = ($r.body | parse -r 'expected LLVM (\d+)\.x' | get 0.capture0)
  datasource versions (purl parse $pkg.upstream.purl) | where { ($in.version | split row "." | first) == $major }
}
