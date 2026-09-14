# lockfile parsing in builder/fetch/*.nu (the parts that need no network)
use fetch/deno.nu [npm-key-id]
use fetch/bun.nu [lock-entries]
use fetch/gems.nu [checksums]
use checks.nu *

# deno.lock npm keys: "<name>@<version>[_<peer>@<version>...]", names may contain "_"
for c in [
  [key name version];
  ["vite@5.0.0_@types+node@20.0.0" vite "5.0.0"]
  ["string_decoder@1.3.0" string_decoder "1.3.0"]
  ["@std/fs@1.0.0_x@1_y@2" "@std/fs" "1.0.0"]
  ["a_b@1.0.0_c_d@2.0.0" a_b "1.0.0"]
] { assert $"deno npm key ($c.key)" ((npm-key-id $c.key) == {name: $c.name, version: $c.version}) }

# bun.lock: workspace members are ["name@workspace:path"] with nothing else
let e = (lock-entries {lodash: ["lodash@4.0.0" "" {} "sha512-xx"], app: ["app@workspace:packages/app"]})
assert "bun registry entry" (($e | where key == lodash | first | select registry integrity) == {registry: "", integrity: "sha512-xx"})
assert "bun workspace entry parses" (($e | where key == app | first).id == "app@workspace:packages/app")

# Gemfile.lock CHECKSUMS: the app's own PATH gem has no sha256 and is not fetched (parse yields
# null for the group that did not match)
let zero = (seq 1 64 | each { '0' } | str join); let aa = (seq 1 64 | each { 'a' } | str join)
let lock = $"GEM\n  specs:\n\nCHECKSUMS\n  myapp \(1.2.3\)\n  rake \(13.0.0\) sha256=($zero)\n  nokogiri \(1.0-x86_64-linux\) sha256=($aa)\n"
assert "gems: checksum-less line dropped" ((checksums $lock | get name) == [rake nokogiri])
assert "gems: platform split" ((checksums $lock | where name == nokogiri | first | select version platform) == {version: "1.0", platform: x86_64-linux})

done
