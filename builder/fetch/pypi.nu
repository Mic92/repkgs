#!/usr/bin/env nu
# Producer for fetch.pythonDeps (arguments: nix/fetch.nix). Walks the project's runtime closure
# in uv.lock and picks a wheel or sdist per package; path and git sources become source trees.
# Second stage pypi-vendor.nu vendors crates for sdists that ship a Cargo.lock.
# Output: dist/<file>…, vendor/<name>/…, plan.json [{name, version, file, kind: wheel|sdist|tree, path}]
use dyn-drv.nu
use ../pep508.nu
use ../sys-libs.nu

const NO_MATCH = 999

def main []: nothing -> nothing {
  let root = ([$env.source $env.root] | path join)
  let lock = (open --raw $"($root)/uv.lock" | from toml)
  let pp = $"($root)/pyproject.toml"
  let pyproject = (if ($pp | path exists) { open --raw $pp | from toml } else { {} })
  if ($lock.version? | default 0) < 1 { error make {msg: "pythonDeps: uv.lock has no `version`, too old"} }
  let csv = {|v| $v | split row "," | where $it != "" }

  let packages = ($lock.package | group-by name)
  let marker_env = ({
    python_full_version: $env.pythonVersion
    python_version: ($env.pythonVersion | split row "." | take 2 | str join ".")
    sys_platform: linux, platform_system: Linux, platform_machine: $env.cpu, os_name: posix
    implementation_name: cpython, implementation_cap: CPython, implementation_version: $env.pythonVersion
    platform_release: "", platform_version: "", extra: ""
  } | merge ($env.environ | from json))
  let git = ($env.git | lines | where $it != "" | parse "{name}={path}" | transpose -rd | default {})
  let project = (project-entry $lock $pyproject)
  let grouped = ($project | upsert dependencies (($project.dependencies? | default []) ++ (do $csv $env.groups | each {|g| $project.dev-dependencies? | default {} | get -o $g | default [] } | flatten)))
  let needed = (runtime-closure $lock.package $grouped (do $csv $env.extras) $marker_env)
  let force_sdist = (($pyproject.tool?.uv?.no-binary-package? | default []) ++ (sys-libs sdist-packages) ++ (do $csv $env.sdist))

  let local = {|p| let s = ($p.source? | default {}); $s.editable? | default $s.directory? | default $s.virtual? }
  let trees = ($needed | where {|p| (do $local $p) != null or $p.source?.git? != null } | each {|p|
    let dir = (do $local $p)
    if $dir != null { return {name: $p.name, version: $p.version, kind: tree, file: "", path: $dir} }
    let g = ($git | get -o $p.name)
    if $g == null { error make {msg: $"pythonDeps: ($p.name) is a git source nix/python.nix did not fetch"} }
    {name: $p.name, version: $p.version, kind: tree, file: $"dist/($p.name)", path: $g}
  })
  let plan = ($needed | where {|p| (do $local $p) == null and $p.source?.git? == null } | par-each --keep-order {|package|
    let name = $package.name
    let artefact = (choose-artefact $package ($name in $force_sdist) ($env.prefer == "sdist"))
    let file = ($artefact.url | path basename | url decode)
    {name: $name, version: $package.version, file: $file, kind: $artefact.kind, url: $artefact.url, sha256: ($artefact.hash | str replace "sha256:" "")}
  } | dyn-drv fetchurls)
  print -e $"pythonDeps: ($plan | length) packages, ($plan | where kind == sdist | get name | str join ' ') from sdist, ($trees | get name | str join ' ') from trees"

  let layout = [
    ...($plan | each {|p| {link: $p.out, to: $"dist/($p.file)"} })
    ...($trees | where file != "" | each {|t| {link: $t.path, to: $t.file} })
    (dyn-drv json-file plan.json (($plan | select name version file kind | insert path "") ++ ($trees | select name version file kind path)))
  ]
  let sdists = ($plan | where kind == sdist)
  dyn-drv stage python-deps pypi-vendor.nu {
    layout: $layout, drvs: ($plan | get -o drv | default []), srcs: ($trees | where file != "" | get path)
    sdists: ($sdists | select name out), trees: ($trees | each {|t| {name: $t.name, dir: (if $t.file == "" { $"($env.source)/($t.path)" } else { $t.path })} })
  } ($sdists | get -o drv | default [])
}

# runtime closure from the project's entry over `dependencies` whose markers hold. uv may fork
# a name into several entries: the edge's version or the entry's resolution-markers pick ours
export def runtime-closure [lock_packages: table, project: record, extras: list<string>, marker_env: record]: nothing -> table {
  let packages = ($lock_packages | group-by name)
  # a lock repeats a handful of distinct markers hundreds of times: evaluate each once
  let all_edges = ($lock_packages | each {|p| ($p.dependencies? | default []) ++ ($p.optional-dependencies? | default {} | values | flatten) } | flatten)
  let markers = ($all_edges | get -o marker) ++ ($lock_packages | get -o resolution-markers | flatten)
  let holds = ($markers | compact | uniq | par-each {|m| [$m (pep508 evaluate $m $marker_env)] } | into record)
  let edges_of = {|package: record, extras: list<string>|
    let optional = ($extras | each {|e| $package.optional-dependencies? | default {} | get -o $e | default [] } | flatten)
    ($package.dependencies? | default []) ++ $optional | where {|edge| $edge.marker? == null or ($holds | get $edge.marker) }
  }
  # name -> {extras already expanded for it, entry}
  mut visited = {}
  mut queue = (do $edges_of $project $extras)
  while ($queue | is-not-empty) {
    let edge = ($queue | first)
    $queue = ($queue | skip 1)
    let wanted_extras = ($edge.extra? | default [])
    let done = ($visited | get -o $edge.name)
    if $done != null and ($wanted_extras | all { $in in $done.extras }) { continue }
    let candidates = ($packages | get $edge.name)
    let target = (if $edge.version? != null {
      $candidates | where version == $edge.version | first
    } else if ($candidates | length) == 1 {
      $candidates | first
    } else {
      let ours = ($candidates | where { ($in.resolution-markers? | default []) | any {|m| $holds | get $m } })
      if ($ours | length) != 1 {
        error make {msg: $"pythonDeps: ($edge.name) has ($candidates | get version | str join ', ') in uv.lock and resolution-markers pick ($ours | length) of them"}
      }
      $ours | first
    })
    $visited = ($visited | upsert $edge.name {extras: (($done.extras? | default []) ++ $wanted_extras | uniq), entry: $target})
    $queue = ($queue ++ (do $edges_of $target $wanted_extras))
  }
  $visited | values | get entry
}

# the lock entry for the project being built (source editable/virtual ".", or by normalised name)
def project-entry [lock: record, pyproject: record]: nothing -> record {
  let name = ($pyproject.project?.name? | default "" | str lowercase | str replace -ar '[-_.]+' "-")
  $lock.package | where { $in.name == $name or $in.source?.editable? == "." or $in.source?.virtual? == "." } | first
}

# {url, hash, kind}: the sdist when preferred or forced (a forced package still takes a pure
# wheel: nothing to link), otherwise the best-ranked compatible wheel, otherwise the sdist
def choose-artefact [package: record, force_sdist: bool, prefer_sdist: bool]: nothing -> record {
  if $package.source?.registry? == null {
    error make {msg: $"pythonDeps: ($package.name) comes from ($package.source? | to nuon), not a registry; uv.lock records no hash for that"}
  }
  let wheels = ($package.wheels? | default []
    | insert rank {|w| wheel-rank ($w.url | path basename) }
    | where rank < $NO_MATCH | sort-by rank)
  let best = ($wheels | get -o 0)
  let sdist = $package.sdist?
  if $prefer_sdist and $sdist != null {
    $sdist | insert kind sdist
  } else if $best != null and (not $force_sdist or $best.rank == 0 or $sdist == null) {
    $best | insert kind wheel
  } else if $sdist != null {
    $sdist | insert kind sdist
  } else {
    error make {msg: $"pythonDeps: ($package.name) ($package.version): no wheel for cp($env.pythonVersion) linux/($env.cpu) and no sdist"}
  }
}

# 0 pure python, 1 built for exactly our cpython, 2 abi3/none for our cpu, NO_MATCH otherwise.
# Wheel names are <name>-<version>[-<build>]-<python tag>-<abi tag>-<platform tag>.whl, tags dot-separated sets
def wheel-rank [file: string]: nothing -> int {
  let fields = ($file | str replace -r '\.whl$' "" | split row "-")
  if ($fields | length) < 5 { return $NO_MATCH }
  let tag = {python: ($fields | get (($fields | length) - 3) | split row "."), abi: ($fields | get (($fields | length) - 2)), platform: ($fields | last | split row ".")}
  let ours = $"cp($env.pythonVersion | split row "." | take 2 | str join "")"  # cp314
  let minor = {|cp: string| $cp | str substring 3.. | into int }

  let python_ok = ($tag.python | any {|t|
    $t == $ours or $t =~ '^py3\d*$' or ($tag.abi == abi3 and $t =~ '^cp3\d+$' and (do $minor $t) <= (do $minor $ours))
  })
  if not $python_ok { return $NO_MATCH }
  if $tag.abi == none and $tag.platform == [any] { return 0 }
  let platform_ok = ($tag.platform | any { $in =~ $"^\(manylinux[0-9_]*|linux\)_($env.cpu)$" })
  if not $platform_ok { return $NO_MATCH }
  match $tag.abi { $abi if $abi == $ours => 1, "abi3" | "none" => 2, _ => $NO_MATCH }
}
