#!/usr/bin/env nu
# Submitted by fetch/winsdk.nu: the CRT .vsix are zips with Contents/VC/Tools/MSVC/<v>/{include,lib},
# the SDK .msi install below "Windows Kits/10/{Include,Lib}/<v>/" out of cabinets whose members
# are named by File-table id (msi.nu maps them). Result: crt/{include,lib} and sdk/{include,lib}/<v>/,
# plus a lowercase symlink for every name with capitals so includes and -l resolve case-sensitively.
use msi.nu

def main []: nothing -> nothing {
  let a = (open $env.NIX_ATTRS_JSON_FILE)
  let out = $a.outputs.out
  $env.PATH = [$"($a.seed)/bin" $"($a.sevenzip)/bin"]
  let work = $"($env.NIX_BUILD_TOP)/w"
  mkdir $"($out)/crt" $"($out)/sdk" $"($work)/in"

  for p in ($a.payloads | where kind == crt) { ^bsdtar -xf $p.out -C $work Contents/VC/Tools/MSVC }
  let vc = (ls $"($work)/Contents/VC/Tools/MSVC" | first | get name)
  ^cp -r $"($vc)/include" $"($vc)/lib" $"($out)/crt/"

  # 7zz finds an msi's cabinets next to it by the names in its Media table
  for p in ($a.payloads | where kind != crt) { ^ln -s $p.out $"($work)/in/($p.file)" }
  for m in ($a.payloads | where kind == msi) {
    let t = $"($work)/($m.file).t"; let x = $"($work)/($m.file).x"
    ^7zz x -y $"-o($t)" $"($work)/in/($m.file)" o> /dev/null
    for cab in (msi cabinets $t) { ^7zz x -y $"-o($x)" $"($work)/in/($cab)" o> /dev/null }
    for e in (msi install-paths $t | transpose id rel) {
      let rel = ($e.rel | parse -r '^Windows Kits/10/(Include|Lib)/(.*)$')
      if ($rel | is-empty) or not ($"($x)/($e.id)" | path exists) { continue }
      let dst = $"($out)/sdk/($rel.0.capture0 | str downcase)/($rel.0.capture1)"
      mkdir ($dst | path dirname)
      ^mv $"($x)/($e.id)" $dst
    }
  }
  ^chmod -R u+w $out
  # clang's msvc driver appends the installer's spelling
  ^ln -s include $"($out)/sdk/Include"
  ^ln -s lib $"($out)/sdk/Lib"
  for f in (glob $"($out)/**/*") {
    let dir = ($f | path dirname); let b = ($f | path basename); let l = ($b | str downcase)
    if $b != $l and not ($"($dir)/($l)" | path exists) { ^ln -s $b $"($dir)/($l)" }
  }
}
