# fetch-*.nu producers end to end on locks of real-world size (JIG_NIX_STORE_OFFLINE: no daemon).
use fixtures.nu
use ../builder/pep508.nu

const BUILDER = path self ../builder
const MARKER_ENV = {python_full_version: "3.13.1", python_version: "3.13", sys_platform: linux, platform_system: Linux, platform_machine: x86_64
  os_name: posix, implementation_name: cpython, implementation_cap: CPython, platform_release: "", extra: ""}

def produce [script: string, vars: record]: nothing -> nothing {
  with-env $vars { ^$nu.current-exe --no-config-file $"($BUILDER)/($script)" o+e>| ignore }
}

export def benches [tmp: path]: nothing -> table<name: string, note: string, run: closure> {
  let src = $"($tmp)/psrc"
  mkdir $src
  fixtures cargo-lock 600 | save -f $"($src)/Cargo.lock"
  let go = (fixtures go-sum 900)
  $go.sum | save -f $"($src)/go.sum"
  $go.locks | to json | save -f $"($tmp)/go-locks.json"
  let uv = (fixtures uv-lock 300)
  $uv | to toml | save -f $"($src)/uv.lock"
  {project: {name: project, version: "0"}} | to toml | save -f $"($src)/pyproject.toml"
  {} | to json | save -f $"($tmp)/sys-libs.json"
  let vars = {source: $src, root: ".", system: x86_64-linux, cpu: x86_64, pythonVersion: "3.13.1", extras: ""
    seed: /nix/store/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-seed, jig: /nix/store/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-jig
    sysLibs: $"($tmp)/sys-libs.json", locks: $"($tmp)/go-locks.json"}
  let markers = ($uv.package | get dependencies | flatten | get -o marker | compact)
  [
    {name: "producer/cargo-vendor", note: "600 crates", run: {|| produce fetch-cargo.nu $vars }}
    {name: "producer/go-modules", note: "900 modules", run: {|| produce fetch-go.nu $vars }}
    {name: "producer/python-deps", note: "300 packages", run: {|| produce fetch-pypi.nu $vars }}
    {name: "pep508/evaluate", note: $"($markers | length) markers", run: {|| $markers | each {|m| pep508 evaluate $m $MARKER_ENV } | length }}
  ]
}
