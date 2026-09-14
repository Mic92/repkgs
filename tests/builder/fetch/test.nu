# lockfile parsing in builder/fetch/*.nu (the parts that need no network)
use fetch/deno.nu [npm-key-id]
use fetch/bun.nu [lock-entries]
use fetch/gems.nu [checksums]
use fetch/npm.nu [remote-entries relock]
use fetch/go.nu [proxy-case]
use pep508.nu
use fetch/pypi.nu [runtime-closure]
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

# package-lock v3 workspaces: the link entry resolves to a directory and is not fetched
let pkgs = {"node_modules/a": {resolved: "https://r/a.tgz", integrity: "sha512-x"}, "node_modules/@o/w": {resolved: "packages/w", link: true}, "packages/w": {name: "@o/w"}}
assert "npm: workspace link skipped" ((remote-entries $pkgs | get key) == ["node_modules/a"])
assert "npm: link keeps its resolved" ((relock $pkgs {"https://r/a.tgz": "/s/a.tgz"} | get node_modules/@o/w | get resolved) == "packages/w")

# go proxy escapes upper case in versions too
assert "go: proxy-case version" ((proxy-case "v1.0.0-RC1") == "v1.0.0-!r!c1")

# PEP 508 markers as uv writes them
let py = {python_full_version: "3.14.7", python_version: "3.14", sys_platform: linux, implementation_name: cpython}
assert "pep508: wildcard ==" (pep508 evaluate "python_full_version == '3.14.*'" $py)
assert "pep508: wildcard !=" (not (pep508 evaluate "python_full_version != '3.14.*' and sys_platform == 'linux'" $py))
assert "pep508: wildcard other minor" (not (pep508 evaluate "python_full_version == '3.13.*'" $py))
assert "pep508: or after false" (pep508 evaluate "python_version < '3.10' or sys_platform == 'linux'" $py)
fails "pep508: unknown variable is an error, not false" { pep508 evaluate "platform_version == 'x' or sys_platform == 'linux'" $py }

# uv.lock forks: two numpy entries, ours is the one whose resolution-markers hold
let lockp = [
  {name: app, version: "0", dependencies: [{name: numpy}, {name: six, marker: "python_version < '3'"}]}
  {name: numpy, version: "2.0.2", resolution-markers: ["python_full_version < '3.10'"]}
  {name: numpy, version: "2.2.6", resolution-markers: ["python_full_version >= '3.10'"], dependencies: [{name: pinned, version: "2"}]}
  {name: pinned, version: "1"}
  {name: pinned, version: "2"}
  {name: six, version: "1"}
]
let closure = (runtime-closure $lockp ($lockp | first) [] $py | select name version | sort-by name)
assert "pypi: fork by resolution-markers, edge version pin, false marker dropped" ($closure == [[name version]; [numpy "2.2.6"] [pinned "2"]])
done
