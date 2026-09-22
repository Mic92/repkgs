# PE has no RUNPATH and no dependable symlinks: bin/foo.exe is a *copy* of launch.exe, the record's
# PATH names the store dirs holding its DLLs (also the reference Nix sees).

use core.nu *

# a DLL the OS provides: the toolchain has an import library for it (mingw lib/, SDK um/, ucrtbase under ucrt/)
def system-dll [sysroot: string, n: string]: nothing -> bool {
  let stem = ($n | str replace -r '\.dll$' "")
  $n =~ '^(api-ms-win-|ext-ms-)' or ($"($sysroot)/lib/lib($stem).a" | path exists) or (files $"($sysroot)/sdk/lib/*/{um,ucrt}/*/($stem).lib" | is-not-empty)
}

# lowercased, delay-loaded ones (probed at run time, optional) left out
def imports [f: path]: nothing -> list<string> {
  ^llvm-readobj --coff-imports $f | parse -r '(?m)^\s*Import \{\s*Name: (?<n>\S+)' | get n | str lowercase
}

# One PATH for the package: every dir, own or a dependency's, holding a DLL that any of our PEs
# imports, plus what those dependencies recorded for *their* DLLs (dllDirs, transitively filled).
# An import found nowhere and not in the OS is an undeclared dependency: an error now, not at run time
export def main [c: record, renv: record]: nothing -> nothing {
  # the closure: linking libgit2 through pkg-config also links its Requires, libssh2
  let deps = $c.deps.root
  let pes = (files $"($c.out)/**/*.{exe,dll,pyd}")
  let exports = ($deps | each { exports-of $in })
  # the toolchain's runtime DLLs (libc++, libunwind) count like a dependency's, by their real dir
  let dirs = (($pes | path dirname) ++ ($deps | each {|d| [$"($d)/bin" $"($d)/lib"] } | flatten) ++ [$"($c.platform.sysroot)/bin"] | uniq | where { path exists })
  let has = ($dirs | each {|d| {d: $d, dlls: (ls -l $d | update name { path basename | str lowercase })} })
  let need = ($pes | each { imports $in } | flatten | uniq | each {|n|
    let hit = ($has | each {|h| $h.dlls | where name == $n | each {|e| $h.d | path join ($e.target? | default $n) | path expand | path dirname } } | flatten | get -o 0)
    if $hit == null and not (system-dll $c.platform.sysroot $n) {
      error make {msg: $"($n) is imported but neither the package, a dependency nor the OS provides it"}
    }
    $hit
  } | compact) ++ ($exports.dllDirs | flatten) | uniq
  let foreign = ($need | where { not ($in | str starts-with $c.out) })
  for f in ($pes | where { $in ends-with .exe }) {
    let path = ($need | where { $in != ($f | path dirname) } | each { storerel $in $c.out }) ++ ($renv.PATH?.prepend? | default [])
    if ($path | is-empty) and ($renv | is-empty) { continue }
    let rel = ($f | path relative-to $c.out)
    mv $f $"($f | path dirname)/.($f | path basename)"
    {env: ($renv | upsert PATH {prepend: $path}), program: $"{root}/($rel | path dirname)/.($rel | path basename)"} | to json -r | save -f $"($f | path dirname)/.($f | path basename).launch"
    cp $c.platform.launch $f
    note launcher $"($rel): PATH += ($foreign | each { path dirname | path basename } | str join ' ')"
  }
  if ($foreign | is-not-empty) {
    let f = $"($c.out)/exports.json"
    (if ($f | path exists) { open $f } else { {} }) | upsert dllDirs $foreign | to json | save -f $f
  }
}
