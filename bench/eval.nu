#!/usr/bin/env nu
# Evaluation cost, repkgs against the pinned nixpkgs, for the packages both have (bench/eval.nix
# pairs them): bench/eval.nu [--rounds n] [--each jq,git,…] [--save f.json, for eval-plot.py].
# nix-instantiate to .drv, best of n, counters from NIX_SHOW_STATS, peak RSS from GNU time.
# One table: `case` is set (all shared packages), pkg:<name> or first:<n> (a random prefix)
const NIX = path self ./eval.nix

def measure [side: string, names: list<string>, rounds: int]: nothing -> record {
  let stats = (mktemp -t evstats.XXXX)
  let best = (seq 1 $rounds | each {|_|
    let t = (date now)
    let r = (with-env {NIX_SHOW_STATS_PATH: $stats} { ^env NIX_SHOW_STATS=1 time -f %M nix-instantiate -E $"\(import ($NIX)).($side) ''($names | to json -r)''" | complete })
    if $r.exit_code != 0 { error make {msg: $r.stderr} }
    {wall: ((date now) - $t), rss: ($r.stderr | lines | last | into int)} | merge (open $stats | from json)
  } | sort-by wall | first)
  rm $stats
  {
    side: $side
    wall_s: (($best.wall | into int) / 1e9 | math round -p 2)
    cpu_s: ($best.cpuTime | math round -p 2)
    rss_MB: ($best.rss // 1024)
    thunks: $best.nrThunks
    attrs: $best.sets.elements
    calls: $best.nrFunctionCalls
  }
}

def main [--rounds (-n): int = 3, --each: string = "jq,zstd,curl,cmake,git,cpython314", --save: path]: nothing -> nothing {
  let pairs = (^nix-instantiate --eval --json --strict -E $"\(import ($NIX)).pairs" | from json)
  print $"($pairs | length) packages on both sides, aliases: ($pairs | where {|p| $p.our != $p.np } | each { $'($in.our)=($in.np)' } | str join ' ')"
  let order = ($pairs.our | shuffle)
  let cases = ([[case names]; [set $pairs.our]]
    ++ ($each | split row "," | each {|p| {case: $"pkg:($p)", names: [$p]} })
    ++ ([1 5 10 25 50 100 ($order | length)] | each {|k| {case: $"first:($k)", names: ($order | first $k)} }))
  let rows = ($cases | each {|c| [ours theirs] | each {|s| measure $s $c.names $rounds | insert case $c.case } } | flatten | move case side --first)
  print $rows
  let set = ($rows | where case == set)
  print ($set.0 | reject case side | items {|k, v| {k: $k, ratio: (($set.1 | get $k) / $v | math round -p 1)} } | transpose -rd)
  if $save != null { $rows | save -f $save }
}
