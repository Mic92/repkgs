# `<pkg>.bundle`: one of our outputs as a self-contained tree, the shape upstream binary tarballs
# have and `prebuilt = true` unpacks: libraries taken from other store paths copied under lib/,
# NEEDED and RUNPATH pointing there, the standard absolute PT_INTERP, launchers replaced by their
# programs. Nix supplies the closure (exportReferencesGraph) and refuses any reference left over
# (allowedReferences = []). For `repkgs bootstrap`, where upstream ships no binary for a cpu.

use glob.nu *

const LIBC = [libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1]

def elves [dir: path]: nothing -> list<string> {
  ^find $dir -type f | lines | where {|f| (open --raw $f | into binary | bytes at 0..<4) == 0x[7f 45 4c 46] }
}

def dyn [f: path]: nothing -> record<needed: list<string>, runpath: list<string>, interp: string> {
  let d = (^llvm-readelf -dW $f | lines)
  let pick = {|tag| $d | where { $in =~ $"\(($tag)\)" } | each { $in | parse -r '\[(?<v>.*)\]' | get v.0 } }
  let interp = (^llvm-readelf -p .interp $f | complete | get stdout | lines
    | parse -r '^\s*\[\s*\w+\]\s*(?<p>.+)$' | get -o p.0 | default "")
  {needed: (do $pick NEEDED), runpath: (do $pick RUNPATH | each { split row ":" } | flatten), interp: $interp}
}

# lib/ as seen from `dir` under `root`: "", "/../lib", "/../../lib"
def rel-lib [root: string, dir: string]: nothing -> string {
  let down = ($dir | path relative-to $root | path split | where { $in != "" })
  if $down == [lib] { "" } else { "/" + ($down | each { ".." } | append lib | str join "/") }
}

def main []: nothing -> nothing {
  let attrs = (open $env.NIX_ATTRS_JSON_FILE)
  let src = $attrs.package
  let out = $attrs.outputs.out
  # the closure Nix computed, minus the package itself: where foreign libraries may come from
  let closure = ($attrs.closure | get path | where { $in != $src })
  ^cp -r $src $out
  ^chmod -R u+w $out
  rm -f $"($out)/exports.json"
  rm -rf $"($out)/lib/debug"

  # launchers: bin/x -> launch, bin/.x the program, bin/.x.launch the record
  for l in (files $"($out)/bin/.*.launch") {
    let name = ($l | path basename | str replace -r '^\.(.*)\.launch$' "$1")
    rm -f $"($out)/bin/($name)" $l
    mv $"($out)/bin/.($name)" $"($out)/bin/($name)"
  }

  let lib = $"($out)/lib"
  mkdir $lib
  # a foreign library by soname: the first closure member that has it
  let find = {|soname| $closure | each {|p| $"($p)/lib/($soname)" } | where { $in | path exists } | get -o 0 }
  mut queue = (elves $out)
  mut seen = []
  while ($queue | is-not-empty) {
    let f = ($queue | first)
    $queue = ($queue | skip 1)
    if $f in $seen { continue }
    $seen ++= [$f]
    if not ((^llvm-readelf -lW $f) | str contains "DYNAMIC") { continue }
    let d = (dyn $f)
    let reldir = (rel-lib $out ($f | path dirname))
    # anything not resolved inside the tree already ($ORIGIN/x, a binary's $ORIGIN/../lib/x) and
    # not libc: copy it next to ours
    let inside = {|n: string| ($n | str starts-with '$ORIGIN') and ($n | str replace '$ORIGIN' ($f | path dirname) | path expand -n | str starts-with $"($out)/") }
    for n in ($d.needed | where { not (do $inside $in) and ($in | path basename) not-in $LIBC and $in !~ 'ld-linux' }) {
      let base = ($n | path basename)
      let from = (do $find $base)
      if $from == null { if $n =~ "/" { error make {msg: $"bundle: ($f): ($n) not in the closure"} } else { continue } }
      if not ($"($lib)/($base)" | path exists) {
        ^cp -L $from $"($lib)/($base)"
        ^chmod u+w $"($lib)/($base)"
        $queue ++= [$"($lib)/($base)"]
      }
      if $n =~ "/" { ^formatelf --replace-needed $n $"$ORIGIN($reldir)/($base)" $f }
    }
    let keep = ($d.runpath | where { $in !~ '[a-z0-9]{32}-' })
    ^formatelf --set-rpath ($keep | append $"$ORIGIN($reldir)" | uniq | str join ":") $f
    # our executables name ld.so relative to themselves for the entry stub. With the standard
    # absolute path the kernel loads it and the stub only hands over
    if $d.interp starts-with "../" { ^formatelf --set-interpreter $"/lib/($d.interp | path basename)" $f }
  }
  print -e $"bundle: ($seen | length) ELF files, (ls $lib | where type == file | length) in lib/"
}
