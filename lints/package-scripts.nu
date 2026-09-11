#!/usr/bin/env nu
# Has nu parse the build script of each package.nix given (`pkg.script`, what the derivation
# runs) before a build does: a module phase with the wrong signature, a misspelt command in an
# inline phase. Instantiating puts the builder and module copies it `use`s into the store.
def main [...files: path] {
  let root = ($env.FILE_PWD | path dirname)
  let names = ($files | each { path dirname | path basename } | each { $'"($in)"' } | str join " ")
  let scripts = (^nix-instantiate --read-write-mode --eval --strict --json --expr $"let set = import ($root) { }; in map \(n: set.${n}.script or null\) [($names)]" | from json)
  let failed = ($files | zip $scripts | where $it.1 != null | par-each {|p|
    # modules say `use core.nu *` by bare name, the derivation passes the same --include-path
    let tree = ($p.1 | parse -r '^use (\S+)/core\.nu' | get 0.capture0)
    let errors = ($p.1 | ^$nu.current-exe --no-config-file $"--include-path=($tree)" "--experimental-options=[cell-path-types]" --ide-check 50 /dev/stdin
      | lines | each { from json } | where type == diagnostic and severity == Error
      | get message | uniq | each {|m| $"  ($m)" })
    if ($errors | is-empty) { null } else { $"($p.0): generated build script\n($errors | str join "\n")" }
  } | compact)
  if ($failed | is-not-empty) {
    print -e ($failed | str join "\n")
    exit 1
  }
}
