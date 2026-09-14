#!/usr/bin/env nu
# Producer for fetch.pythonDeps { source, python, root?, extras? }.
#
# Walks the application's runtime dependency graph in uv.lock (markers evaluated for our platform
# and python) and picks one artefact per package the way uv2nix does with sourcePreference =
# "wheel": a compatible wheel when the lock has one, else the sdist. Packages that must link one of
# our libraries (sys-libs.nu) and pyproject's `tool.uv.no-binary-package` are built from sdist.
# Output: { dist/<file>…, plan.json [{name, version, file, kind}] }, installed by
# builder/pyapp.nu.
use dyn-drv.nu
use ../pep508.nu
use ../sys-libs.nu

const NO_MATCH = 999

def main []: nothing -> nothing {
  let root = ([$env.source $env.root] | path join)
  let lock = (open --raw $"($root)/uv.lock" | from toml)
  let pyproject = (open --raw $"($root)/pyproject.toml" | from toml)
  if ($lock.version? | default 0) < 1 { error make {msg: "pythonDeps: uv.lock has no `version`, too old"} }

  let packages = ($lock.package | group-by name)
  let marker_env = {
    python_full_version: $env.pythonVersion
    python_version: ($env.pythonVersion | split row "." | take 2 | str join ".")
    sys_platform: linux, platform_system: Linux, platform_machine: $env.cpu, os_name: posix
    implementation_name: cpython, implementation_cap: CPython, implementation_version: $env.pythonVersion
    platform_release: "", platform_version: "", extra: ""
  }
  let needed = (runtime-closure $lock.package (project-entry $lock $pyproject) ($env.extras | split row "," | where $it != "") $marker_env)
  let force_sdist = (($pyproject.tool?.uv?.no-binary-package? | default []) ++ (sys-libs sdist-packages))

  let plan = ($needed | par-each --keep-order {|package|
    let name = $package.name
    let artefact = (choose-artefact $package ($name in $force_sdist))
    let file = ($artefact.url | path basename | url decode)
    {name: $name, version: $package.version, file: $file, kind: $artefact.kind, url: $artefact.url, sha256: ($artefact.hash | str replace "sha256:" "")}
  } | dyn-drv fetchurls)
  print -e $"pythonDeps: ($plan | length) packages, ($plan | where kind == sdist | get name | str join ' ') from sdist"

  let layout = [
    ...($plan | each {|p| {link: $p.out, to: $"dist/($p.file)"} })
    (dyn-drv json-file plan.json ($plan | select name version file kind))
  ]
  dyn-drv collect python-deps $layout ($plan | get drv)
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
  let name = ($pyproject.project.name | str lowercase | str replace -ar '[-_.]+' "-")
  $lock.package | where { $in.name == $name or $in.source?.editable? == "." or $in.source?.virtual? == "." } | first
}

# {url, hash, kind} for one package: best-ranked compatible wheel unless an sdist is forced (a
# pure wheel still wins then: nothing to link), else the sdist
def choose-artefact [package: record, force_sdist: bool]: nothing -> record {
  if $package.source?.registry? == null {
    error make {msg: $"pythonDeps: ($package.name) comes from ($package.source? | to nuon), not a registry; uv.lock records no hash for that"}
  }
  let wheels = ($package.wheels? | default []
    | insert rank {|w| wheel-rank ($w.url | path basename) }
    | where rank < $NO_MATCH | sort-by rank)
  let best = ($wheels | get -o 0)
  if $best != null and (not $force_sdist or $best.rank == 0) {
    $best | insert kind wheel
  } else if $package.sdist? != null {
    $package.sdist | insert kind sdist
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
