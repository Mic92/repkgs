# The `debug` output: DWARF split off what jig linked, by build-id. ELF only so far
use core.nu *

# DWARF -> `debug` under lib/debug/.build-id/, .symtab and a .gnu_debuglink stay. Only for what
# jig linked (its package note): no DWARF and no debuglink there means the build strips, an error.
# Upstream binaries and ours copied from a dependency (already split) are left alone
export def split-debug [out: path, debug: path, njobs: int, files: table]: nothing -> nothing {
  strip-archives $out ($files | where rel =~ '\.[ao]$')
  let elfs = (elf-table ($files | where size > 3072 and rel !~ '\.(a|o|rlib)$' | get path) $njobs)
  let stripped = ($elfs | where {|e| $e.ours and not $e.dwarf and not $e.split })
  if ($stripped | is-not-empty) {
    error make {msg: $"debug: linked here but no DWARF: ($stripped.file | first 3 | path relative-to $out | str join ' '). The build strips or drops -g. Fix that, or debug = false"}
  }
  let foreign = ($elfs | where {|e| not $e.ours or $e.split })
  if ($foreign | is-not-empty) {
    note debug $"($foreign | length) ELF files not linked here left as they are \(($foreign.file | first 2 | path basename | str join ' ')…)"
  }
  let ours = ($elfs | where {|e| $e.ours and not $e.split })
  if ($ours | is-empty) { return }
  ^chmod u+w ...$ours.file
  # one build-id twice is one binary installed twice: one .debug serves both
  $ours | group-by id --to-table | par-each --threads $njobs {|g|
    let dbg = $"($debug)/lib/debug/.build-id/($g.id | str substring 0..<2)/($g.id | str substring 2..).debug"
    mkdir ($dbg | path dirname)
    ^llvm-objcopy --only-keep-debug $g.items.0.file $dbg
    for f in $g.items.file { ^llvm-objcopy --strip-debug $"--add-gnu-debuglink=($dbg)" $f }
  } | ignore
  note debug $"($ours.id | uniq | length) files, (du $debug | get 0.apparent)"
}

# objcopy fails on archives with non-object members (LTO bitcode, lib.rmeta): those keep DWARF
def strip-archives [out: path, archives: table]: nothing -> nothing {
  if ($archives | is-empty) { return }
  ^chmod u+w ...$archives.path
  for f in $archives {
    if (^llvm-objcopy --strip-debug $f.path | complete).exit_code != 0 { note debug $"DWARF left in ($f.rel)" }
  }
}

# build-id, .debug_info and .gnu_debuglink presence per ELF, readelf batched and split at its "File:" headers
def elf-table [candidates: list<string>, njobs: int]: nothing -> table<file: string, id: any, ours: bool, dwarf: bool, split: bool> {
  $candidates
  | where { is-elf $in }
  | chunks 64 | par-each --threads $njobs {|batch|
    let text = (^llvm-readelf -S -n ...$batch)
    let per_file = (if ($batch | length) == 1 { [$"($batch.0)\n($text)"] } else { $"\n($text)" | split row "\nFile: " | skip 1 })
    $per_file | each {|t|
      # 0xcafe1a7e: the FDO package note jig links in
      {file: ($t | lines | first), id: ($t | parse -r 'Build ID: ([0-9a-f]+)' | get -o capture0.0), ours: ($t | str contains "0xcafe1a7e"), dwarf: ($t | str contains ".debug_info"), split: ($t | str contains ".gnu_debuglink")}
    }
  } | flatten
}

