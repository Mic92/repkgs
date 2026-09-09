# uptrack hook. rust N is built by exactly the compiler its src/stage0 names (N-1 usually), so
# rust-bootstrap follows the tree's rust pin instead of upstream's latest release.
use http.nu *

export def resolve [pkg: record]: nothing -> table {
  let rust = (open ($pkg.dir | path dirname | path join rust sources.toml)).pin.version
  let url = $"https://raw.githubusercontent.com/rust-lang/rust/($rust)/src/stage0"
  let r = (http cached $url --max-age 1day)
  if $r.status != 200 { error make {msg: $"GET ($url) → ($r.status)"} }
  let v = ($r.body | lines | parse "compiler_version={v}" | get 0.v)
  [{version: $v, date: null, prerelease: false}]
}
