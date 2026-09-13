# `use checks.nu *` in tests/builder/*/test.nu. $env.pkg, $env.debug: the package under test
export def assert [what: string, ok: bool] { if not $ok { error make {msg: $"FAIL: ($what)"} } }
export def fails [what: string, body: closure] { assert $what (try { do $body; false } catch { true }) }
export def has-section [f: string, s: string]: nothing -> bool { ^llvm-readelf -S $"($env.pkg)/($f)" | str contains $s }
# split right: no DWARF left, .symtab kept, the DWARF in a .debug under the file's build-id
export def has-debug [f: string] {
  let id = (^llvm-readelf -n $"($env.pkg)/($f)" | parse -r 'Build ID: ([0-9a-f]+)' | get -o capture0.0)
  assert $"($f) has a build-id" ($id != null)
  assert $"($f) DWARF moved out" (not (has-section $f .debug_info))
  assert $"($f) keeps .symtab" (has-section $f .symtab)
  let d = $"($env.debug)/lib/debug/.build-id/($id | str substring 0..<2)/($id | str substring 2..).debug"
  assert $"($f) has its .debug with DWARF" (($d | path exists) and (^llvm-readelf -S $d | str contains .debug_info))
}
export def done [] { mkdir $env.out }
