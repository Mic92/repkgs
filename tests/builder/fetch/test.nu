# lockfile parsing in builder/fetch/*.nu (the parts that need no network)
use fetch/deno.nu [npm-key-id]
use fetch/bun.nu [lock-entries]
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
done
