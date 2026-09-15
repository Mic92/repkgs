# File names per platform from nix/platforms.nix `ext` ({exe shared static import} plus binfmt).
# Leaf module: core.nu wraps these with the build's platform, exports.nu reads other outputs with them.

# `shlib $p z` -> libz.so | libz.dylib | libz.dll, `shlib $p z 1` -> libz.so.1 | libz.1.dylib | libz-1.dll
export def shlib [p: record, name: string, version?: string]: nothing -> string {
  let v = (if $version == null { "" } else if $p.binfmt == "coff" { $"-($version)" } else { $".($version)" })
  if $p.binfmt == "elf" { $"lib($name)($p.ext.shared)($v)" } else { $"lib($name)($v)($p.ext.shared)" }
}

# what `-l<name>` resolves to: the shared library, or its import library where the platform has those
export def linklib [p: record, name: string]: nothing -> string {
  $"lib($name)($p.ext.import? | default $p.ext.shared)"
}

# the <name> in lib<name><linkext> for every linkable library under `libdir`
export def linkable-libs [p: record, libdir: string]: nothing -> list<string> {
  let x = ($p.ext.import? | default $p.ext.shared)
  if not ($libdir | path exists) { return [] }
  ls --short-names $libdir | get name | where { ($in | str starts-with lib) and ($in | str ends-with $x) } | each { str substring 3..<(-1 * ($x | str length)) }
}

# where shared libraries are installed and found at run time: beside the executables on PE
export def shlibdir [p: record]: nothing -> string { if $p.binfmt == "coff" { "bin" } else { "lib" } }
