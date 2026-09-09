#!/usr/bin/env nu
# Producer for fetch.pythonDeps { source, python, root?, extras? }.
#
# Walks the application's runtime dependency graph in uv.lock (markers evaluated for our platform
# and python) and picks one artefact per package the way uv2nix does with sourcePreference =
# "wheel": a compatible wheel when the lock has one, else the sdist. Packages that must link one of
# our libraries (sys-libs.nu) and pyproject's `tool.uv.no-binary-package` are built from sdist.
# Output: { dist/<file>…, plan.json [{name, version, file, kind}], exports.json }, installed by
# builder/pyapp.nu.
use dynamic.nu
use pep508.nu
use sys-libs.nu

const NO_MATCH = 999

def main []: nothing -> nothing {
  let root = ([$env.source $env.root] | path join)
  let lock = (open --raw $"($root)/uv.lock" | from toml)
  let pyproject = (open --raw $"($root)/pyproject.toml" | from toml)
  if ($lock.version? | default 0) < 1 { error make {msg: "pythonDeps: uv.lock has no `version`, too old"} }

  let packages = ($lock.package | group-by name)
  let names = (runtime-closure $lock $pyproject ($env.extras | split row "," | where $it != ""))
  let force_sdist = (($pyproject.tool?.uv?.no-binary-package? | default []) ++ (sys-libs sdist-packages))
  let libs = (sys-libs pick python $names $env.sysLibs)

  let plan = ($names | par-each --keep-order {|name|
    let package = ($packages | get $name | first)
    let artefact = (choose-artefact $package ($name in $force_sdist))
    let file = ($artefact.url | path basename | url decode)
    {name: $name, version: $package.version, file: $file, kind: $artefact.kind, url: $artefact.url, sha256: ($artefact.hash | str replace "sha256:" "")}
  } | dynamic fetchurls)
  print -e $"pythonDeps: ($plan | length) packages, ($plan | where kind == sdist | get name | str join ' ') from sdist"

  let layout = [
    ...($plan | each {|p| {link: $p.out, to: $"dist/($p.file)"} })
    (dynamic json-file plan.json ($plan | select name version file kind))
    (dynamic json-file exports.json (sys-libs exports python-deps $libs))
  ]
  dynamic collect python-deps $layout (($plan | get drv) ++ ($libs | get -o drv | default []))
}

# names of every package the project needs at run time: breadth-first from the project's own
# lock entry over `dependencies` (+ requested extras), skipping edges whose marker is false here
def runtime-closure [lock: record, pyproject: record, extras: list<string>]: nothing -> list<string> {
  let marker_env = {
    python_full_version: $env.pythonVersion
    python_version: ($env.pythonVersion | split row "." | take 2 | str join ".")
    sys_platform: linux, platform_system: Linux, platform_machine: $env.cpu, os_name: posix
    implementation_name: cpython, implementation_cap: CPython, platform_release: "", extra: ""
  }
  let packages = ($lock.package | group-by name)
  let project = (project-entry $lock $pyproject)
  # a lock repeats a handful of distinct markers hundreds of times: evaluate each once
  let all_edges = ($lock.package | each {|p| ($p.dependencies? | default []) ++ ($p.optional-dependencies? | default {} | values | flatten) } | flatten)
  let holds = ($all_edges | get -o marker | compact | uniq | par-each {|m| [$m (pep508 evaluate $m $marker_env)] } | into record)
  let edges_of = {|package: record, extras: list<string>|
    let optional = ($extras | each {|e| $package.optional-dependencies? | default {} | get -o $e | default [] } | flatten)
    ($package.dependencies? | default []) ++ $optional | where {|edge| $edge.marker? == null or ($holds | get $edge.marker) }
  }
  # name -> extras already expanded for it
  mut visited = {}
  mut queue = (do $edges_of $project $extras)
  while ($queue | is-not-empty) {
    let edge = ($queue | first)
    $queue = ($queue | skip 1)
    let wanted_extras = ($edge.extra? | default [])
    let done_extras = ($visited | get -o $edge.name)
    if $done_extras != null and ($wanted_extras | all { $in in $done_extras }) { continue }
    $visited = ($visited | upsert $edge.name (($done_extras | default []) ++ $wanted_extras | uniq))
    # several lock entries share a name only under conflicting forks; the edge then pins a version
    let candidates = ($packages | get $edge.name)
    let target = (if $edge.version? != null { $candidates | where version == $edge.version | first } else { $candidates | first })
    $queue = ($queue ++ (do $edges_of $target $wanted_extras))
  }
  $visited | columns
}

# the lock entry for the project being built (source editable/virtual ".", or by normalised name)
def project-entry [lock: record, pyproject: record]: nothing -> record {
  let name = ($pyproject.project.name | str downcase | str replace -ar '[-_.]+' "-")
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
