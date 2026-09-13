#!/usr/bin/env nu
# Builder hot paths on synthetic fixtures: bench/run.nu [name…] [-n rounds] [--save f | --compare f]
use std/bench
use builder.nu
use producers.nu
use finish.nu

const HERE = path self .

def main [
  ...only: string          # substrings of bench names to run (default: all)
  --rounds (-n): int = 5
  --jig: path              # default: nix-build bootstrap -A stage0.jig
  --seed: path             # clang, llvm-objcopy, llvm-readelf for the finish benches
  --save: path             # write results as json
  --compare: path          # print the ratio against a saved run
  --keep                   # leave the fixtures in place
]: nothing -> nothing {
  let jig = ($jig | default (^nix-build $"($HERE)/../bootstrap" -A stage0.jig --no-out-link | str trim))
  let seed = ($seed | default (^nix-build $"($HERE)/../bootstrap" -A seed --no-out-link | str trim))
  let tmp = (mktemp -d -t pkgs-bench.XXXX)
  $env.NIX_STORE = "/nix/store"
  $env.NIX_BUILD_TOP = $tmp
  $env.PATH = ([$"($jig)/bin" $"($seed)/bin"] ++ $env.PATH)
  $env.JIG_NIX_STORE_OFFLINE = "1"
  let all = ((builder benches $tmp) ++ (finish benches $tmp $seed) ++ (producers benches $tmp))
  let chosen = (if ($only | is-empty) { $all } else { $all | where {|b| $only | any {|o| $b.name | str contains $o } } })
  let old = (if $compare != null { open $compare } else { [] })
  let results = ($chosen | each {|b|
    let r = (bench -n $rounds -w 1 $b.run)
    let row = {name: $b.name, mean: $r.mean, std: $r.std, note: $b.note}
    let was = ($old | where name == $b.name | get -o 0.mean)
    let row = (if $was != null { $row | insert was ($was | into duration) | insert ratio (($r.mean / ($was | into duration)) | math round -p 2) } else { $row })
    print -e $"  ($b.name): ($r.mean | format duration ms)"
    $row
  })
  print ($results | reject note | update mean { format duration ms } | update std { format duration ms } | table -e)
  if $save != null { $results | update mean { into int } | update std { into int } | to json | save -f $save }
  if $keep { print -e $"kept ($tmp)" } else { rm -rf $tmp }
}
