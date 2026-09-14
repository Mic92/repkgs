# repkgs dev: no second description of a build, the derivation's own nu script (last of `args`)
# with `prepare` swapped for DEV_PREPARE and each phase block turned into a `phase <name>` command.
# The .drv is unresolved, so structuredAttrs holds CA placeholders where input paths go:
# resolve-placeholders computes them as Nix does and substitutes the realised paths, which is
# the part nix-shell on the .drv cannot do
use nix.nu *

# spliced into the derivation's script in place of its `prepare` line
const DEV_PREPARE = r#'
$env.NIX_BUILD_TOP = "@top@"
$env.NIX_ATTRS_JSON_FILE = "@top@/.attrs.json"
$env.NIX_STORE = "/nix/store"
cd "@top@"
# second entry: --from-tree with an empty tarball restores nothing and keeps source/ as edited
if ("@top@/source" | path exists) { prepare --from-tree "@top@/keep" } else { prepare }
# jig reads JIG_SOCK itself, rustc/go wrappers need the env prepare only sets inside the sandbox
if ($env.JIG_SOCK? != null) { use @build@/env.nu; load-env (env compiler-caches) }
'#

# the derivation's script as rc.nu: modules and setups run, each phase becomes `phase <name>`,
# `phases` lists them, finish is left out
def dev-rc [script: string, top: string]: nothing -> string {
  let lines = ($script | lines)
  let at_prepare = ($lines | enumerate | where item == "prepare" | get 0.index)
  let first_phase = ($lines | enumerate | where item starts-with "note phase " | get 0?.index | default ($lines | length))
  let build = ($lines | first | parse -r '^use (.*)/core.nu' | get capture0.0)
  let prep = ($DEV_PREPARE | str replace -a "@top@" $top | str replace -a "@build@" $build)
  let head = ($lines | take $at_prepare) ++ [$prep] ++ ($lines | slice ($at_prepare + 1)..<$first_phase)
  # phase blocks: from one `note phase X` to the next, or to finish
  let body = ($lines | slice $first_phase.. | where $it !~ '^finish( |$)')
  let starts = ($body | enumerate | where item starts-with "note phase " | get index) ++ [($body | length)]
  let phases = ($starts | window 2 | each {|w|
    let name = ($body | get $w.0 | str replace "note phase " "")
    {name: $name, code: ($body | slice ($w.0 + 1)..<$w.1 | str join "\n")}
  })
  let defs = ($phases | each {|p| $"def --env \"phase ($p.name)\" [] {\n($p.code)\n}" })
  let list = $"def phases [] { ($phases.name | to nuon) }"
  let hello = $"print $\"repkgs dev: \(pwd\). `phases` lists them, `phase <name>` runs one\""
  $head ++ $defs ++ [$list $hello] | str join "\n"
}

# CA inputs are placeholders until Nix resolves the derivation: realise the inputs, compute
# "/" + nix32(sha256("nix-upstream-output:<drv hash>:<name>[-<out>]")) for each. A dynamic
# derivation input's placeholder is the one left over, a package has at most one
def resolve-placeholders [v: record, attrs_json: string]: nothing -> record {
  let inputs = ($v.inputs.drvs | transpose drv want | each {|i|
    # newer nix prints inputs as store basenames
    let drv = ("/nix/store" | path join ($i.drv | path basename))
    let dyn = ($i.want.dynamicOutputs | transpose o w | each {|d| $"($drv)^($d.o)^($d.w.outputs | str join ',')" })
    {drv: $drv, static: (if ($i.want.outputs | is-empty) { [] } else { [$"($drv)^($i.want.outputs | str join ',')"] }), dyn: $dyn}
  })
  let built = (^nix ...$XP build --no-link --json ...(cache-args) ...($inputs.static | flatten) ...($inputs.dyn | flatten) | from json)
  let static = ($built | where ($it.drvPath | describe) == "string" | each {|b|
    let hash = ($b.drvPath | path basename | str substring 0..<32)
    let name = ($b.drvPath | path parse | get stem | str substring 33..)
    $b.outputs | transpose out path | each {|o|
      let out_name = (if $o.out == "out" { $name } else { [$name $o.out] | str join "-" })
      {clear: (["nix-upstream-output" $hash $out_name] | str join ":"), path: $o.path}
    }
  } | flatten)
  # one nix eval for all hashes
  let list = ($static.clear | each {|s| $'"($s)"' } | str join " ")
  let ph = r#'map (s: "/" + builtins.convertHash { hash = builtins.hashString "sha256" s; hashAlgo = "sha256"; toHashFormat = "nix32"; })'#
  let phs = (^nix ...$XP eval --json --expr $"[($list)]" --apply $ph | from json)
  let known = ($phs | zip $static.path | into record)
  let dynamic = ($built | where ($it.drvPath | describe) != "string" | each {|b| $b.outputs | values } | flatten)
  let left = ($attrs_json | parse -r r#'(/[0-9a-df-np-sv-z]{52})\b'# | get capture0 | uniq | where $it not-in ($known | columns))
  if ($left | length) != ($dynamic | length) { fail $"placeholders left unresolved: ($left)" }
  $known | merge ($left | zip $dynamic | into record)
}

# lay out <top> like the sandbox: .attrs.json with outputs under <top>/outputs, rc.nu to source,
# nu = the builder's nu. Kept per .drv: same drv, nothing to do
def dev-tree [d: string, top: string]: nothing -> string {
  let stamp = $"($top)/drv"
  if ($stamp | path exists) and (open --raw $stamp) == $d { return $"($top)/nu" }
  let show = (^nix ...$XP derivation show $d | from json)
  let v = ($show | get -o derivations | default $show | values | first)
  let raw = ($v.structuredAttrs | to json)
  let map = (resolve-placeholders $v $raw)
  let attrs = ($map | transpose ph path | reduce -f $raw {|m, acc| $acc | str replace -a $m.ph $m.path } | from json)
  mkdir $"($top)/outputs" $"($top)/keep"
  let outputs = ($v.outputs | columns | each {|o| [$o $"($top)/outputs/($o)"] } | into record)
  # `package` is where prepare --from-tree (second entry) points ctx.out: the same prefix a first entry installs to
  $attrs | upsert outputs $outputs | upsert package $"($top)/prefix" | to json | save -f $"($top)/.attrs.json"
  if not ($"($top)/keep/tree.tar.zst" | path exists) { ^bsdtar -caf $"($top)/keep/tree.tar.zst" --files-from /dev/null }
  dev-rc ($v.args | last) $top | save -f $"($top)/rc.nu"
  # the builder's nu with the builder's flags (--include-path for package modules), minus `-c <script>`
  let flags = ($v.args | take (($v.args | length) - 2) | where $it != "--no-config-file")
  rm -f $"($top)/nu"
  $"#!/bin/sh\nexec ($v.builder) ($flags | str join ' ') \"$@\"\n" | save -f $"($top)/nu"
  chmod +x $"($top)/nu"
  $d | save -f $stamp
  $"($top)/nu"
}

# the package's build by hand in a tree that stays (tools/repkgs/README.md)
export def "main dev" [
  --for: string # platform
  --fresh # remove the tree first
  --reset # unpack and patch the source again, keep the rest
  attr: string
  ...cmds: string # nu to run instead of an interactive shell
]: nothing -> nothing {
  let top = ($env.XDG_CACHE_HOME? | default $"($env.HOME)/.cache") | path join repkgs dev $"($attr)-($for | default native)"
  if $fresh { rm -rf $top }
  if $reset { rm -rf $"($top)/source" $"($top)/build" $"($top)/outputs" }
  mkdir $top
  # rooted: with keep-outputs the .drv holds the inputs while the tree exists
  let d = (^nix-instantiate (root) ...$XP -A $attr ...(platform-arg $for) --add-root $"($top)/drv-root" --indirect | str trim)
  let d = ($d | path expand)
  let nush = (dev-tree $d $top)
  let rc = $"($top)/rc.nu"
  let run = (if ($cmds | is-empty) { [-e $"source ($rc)"] } else { [-c $"source ($rc); ($cmds | str join ' ')"] })
  let sock = (jigd-socket)
  let keep = [$"TERM=($env.TERM? | default 'dumb')"] ++ (if $sock == null { [] } else { [$"JIG_SOCK=($sock)"] })
  ^env -i ...$keep $nush --no-config-file ...$run
}

