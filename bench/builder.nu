# Per-package builder paths that touch every file of a source tree or output.
use fixtures.nu
use ../builder/core.nu *

export def benches [tmp: path]: nothing -> table<name: string, note: string, run: closure> {
  let src = (fixtures source-tree $"($tmp)/source")
  let deps = (fixtures dep-store $"($tmp)/store")
  let out = (fixtures prefix $"($tmp)/store/('' | fill -w 32 -c o)-out")
  let log = (fixtures jig-log $"($tmp)/jig.log")
  [
    {name: "prepare/fix-env-shebangs", note: "3000 files, 120 env scripts", run: {||
      ^cp -rp $src $"($src).run"; fix-env-shebangs $"($src).run" 8; rm -rf $"($src).run" }}
    {name: "prepare/dep-closure", note: "8 roots, 60 store paths via propagate", run: {|| dep-closure ($deps | first 8) | length }}
    {name: "core/exports-of", note: "one dependency, defaults from the tree", run: {|| exports-of ($deps | last) }}
    {name: "finish/elf-scan", note: "380 files under bin+lib, is-elf each", run: {||
      glob $"($out)/{bin,lib,libexec}/**/*" | where { ($in | path type) == "file" and (is-elf $in) } | length }}
    {name: "finish/cache-summary", note: "20k-line jig.log tallied by kind", run: {||
      open --raw $log | lines | where { $in !~ "^gocacheprog" } | each { split row " " | first } | uniq -c | length }}
  ]
}
