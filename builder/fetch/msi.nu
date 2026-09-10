# Just enough of the Windows Installer table format, read from the streams `7zz x foo.msi`
# leaves behind (!_StringPool, !_StringData, !_Columns, !<Table>): tables are column-major,
# integers offset by 0x8000 / 0x80000000, strings are indexes into the pool.

def int-at [b: binary, at: int, w: int]: nothing -> int { $b | bytes at $at..<($at + $w) | into int --endian little }

def string-pool [dir: path]: nothing -> record<strings: list<any>, ref: int> {
  let p = (open --raw $"($dir)/!_StringPool" | into binary)
  let d = (open --raw $"($dir)/!_StringData" | into binary)
  mut strings: list<any> = [null]; mut i = 4; mut off = 0
  while $i < ($p | bytes length) {
    mut len = (int-at $p $i 2); let refs = (int-at $p ($i + 2) 2); $i += 4
    if $len == 0 and $refs != 0 { $len = (int-at $p $i 4); $i += 4 }
    $strings ++= [($d | bytes at $off..<($off + $len) | decode utf-8)]
    $off += $len
  }
  {strings: $strings, ref: (if (int-at $p 0 4) >= 0x80000000 { 3 } else { 2 })}
}

# kinds: s (string ref), 2 or 4 (integer bytes) per column
def rows [raw: binary, kinds: list<any>, pool: record]: nothing -> list<list<any>> {
  let widths = ($kinds | each {|k| if $k == s { $pool.ref } else { $k } })
  let n = (($raw | bytes length) // ($widths | math sum))
  if $n == 0 { return [] }
  let starts = ($widths | reduce --fold [0] {|w, acc| $acc | append (($acc | last) + $n * $w) })
  0..<$n | each {|r|
    $kinds | enumerate | each {|c|
      let w = ($widths | get $c.index)
      let v = (int-at $raw (($starts | get $c.index) + $r * $w) $w)
      let v = (if $c.item == s { $pool.strings | get -o $v } else if $v == 0 { null } else if $w == 2 { $v - 0x8000 } else { $v - 0x80000000 })
      {v: $v}
    }
  }
}

export def read [dir: path, name: string]: nothing -> table {
  let pool = (string-pool $dir)
  let cols = (rows (open --raw $"($dir)/!_Columns" | into binary) [s 2 s 2] $pool
    | where { $in.0.v == $name } | each {|r| {name: $r.2.v, kind: (if ($r.3.v | bits and 0x800) != 0 { "s" } else if ($r.3.v | bits and 0xff) == 2 { 2 } else { 4 })} })
  let f = $"($dir)/!($name)"
  if ($cols | is-empty) or not ($f | path exists) { return [] }
  rows (open --raw $f | into binary) $cols.kind $pool | each {|r| $cols.name | zip ($r | get v) | into record }
}

export def cabinets [dir: path]: nothing -> list<string> { read $dir Media | get Cabinet | compact }

# {<File id, the cabinet member name>: <install path>}
export def install-paths [dir: path]: nothing -> record {
  let dirs = (read $dir Directory)
  let comp_dir = (read $dir Component | select Component Directory_ | transpose -r -d)
  let long = {|s: string| $s | split row "|" | last | split row ":" | first }
  def dir-path [dirs: table, long: closure, id: any]: nothing -> list<string> {
    let d = ($dirs | where Directory == $id)
    if ($d | is-empty) { return [] }
    let n = (do $long $d.0.DefaultDir)
    (dir-path $dirs $long $d.0.Directory_Parent) ++ (if $n in [. SourceDir] { [] } else { [$n] })
  }
  read $dir File | each {|f| [$f.File ((dir-path $dirs $long ($comp_dir | get $f.Component_)) | append (do $long $f.FileName) | path join)] } | into record
}
