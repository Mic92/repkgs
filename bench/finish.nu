# builder/finish.nu steps on an installed prefix the size of a mid-sized package.
use fixtures.nu
use ../builder/core.nu *
use ../builder/finish.nu [inventory prune layout-check]
use ../builder/debug.nu [split-debug]
use ../builder/exports.nu [write-exports]

# a fresh copy per round: the steps modify the tree
def on-copy [out: path, body: closure]: nothing -> any {
  rm -rf $"($out).run"
  ^cp -rp $out $"($out).run"
  do $body $"($out).run"
}

export def benches [tmp: path, seed: path]: nothing -> table<name: string, note: string, run: closure> {
  let out = (fixtures output $"($tmp)/store/('' | fill -w 32 -c p)-pkg" $seed)
  let deps = (fixtures dep-store $"($tmp)/depstore" | each {|r| {root: $r} })
  let n = (^find $out -type f | lines | length)
  [
    {name: "finish/copy-only", note: "the per-round cp the other finish benches include", run: {|| on-copy $out {|o| null } }}
    {name: "finish/prune", note: $"($n) files: .la, docs, pch, man .gz", run: {|| on-copy $out {|o| prune $o (inventory $o) } }}
    {name: "finish/layout-check", note: $"($n) files, 60 symlinks", run: {|| on-copy $out {|o| layout-check $o } }}
    {name: "finish/fix-shebangs-undo", note: $"($n) files", run: {|| on-copy $out {|o| fix-shebangs $o 8 --undo } }}
    {name: "finish/split-debug", note: "120 ELF with DWARF, 8 jobs", run: {|| on-copy $out {|o| mkdir $"($o)-debug"; split-debug $o $"($o)-debug" 8 (inventory $o | where type == f) } }}
    {name: "finish/exports-of", note: "include, lib, pkgconfig scan", run: {|| exports-of $out }}
    {name: "finish/write-exports", note: "6 .pc + 1 cmake config resolved against 60 deps", run: {|| write-exports $out {name: pkg} $deps }}
  ]
}
