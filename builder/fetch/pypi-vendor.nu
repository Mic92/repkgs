#!/usr/bin/env nu
# Second stage of fetch.pythonDeps (after pypi.nu, `stage_attrs` carries its layout and the
# fetched sdists): sdists and source trees with a Cargo.lock get their crates vendored under
# vendor/<name>/ (fetch/cargo.nu's layout), then everything is collected.
use dyn-drv.nu
use cargo.nu [vendor-layout]

def main []: nothing -> nothing {
  let s = (open $env.stage_attrs)
  let from_sdist = ($s.sdists | each {|d|
    let locks = (^bsdtar -tf $d.out | lines | where { ($in | path split | length) == 2 and ($in | path basename) == "Cargo.lock" })
    if ($locks | is-empty) { null } else { {name: $d.name, lock: (^bsdtar -xOf $d.out ($locks | first))} }
  } | compact)
  let from_tree = ($s.trees | each {|t| let f = $"($t.dir)/Cargo.lock"; if ($f | path exists) { {name: $t.name, lock: (open --raw $f)} } } | compact)
  let vendors = ($from_sdist ++ $from_tree | each {|v| vendor-layout $v.lock $"vendor/($v.name)/" })
  if ($vendors | is-not-empty) { print -e $"pythonDeps: crates for ($from_sdist ++ $from_tree | get name | str join ' ')" }
  dyn-drv collect python-deps ($s.layout ++ ($vendors | get layout | flatten)) ($s.drvs ++ ($vendors | get drvs | flatten)) --srcs $s.srcs
}
