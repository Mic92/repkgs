# core.nu fix-shebangs: interpreters from PATH, arguments kept, --undo restores the original
use core.nu *
use checks.nu *

let dir = (mktemp -d)
$env.NIX_BUILD_TOP = (mktemp -d)
let cases = {
  env: "#!/usr/bin/env sh\necho"
  args: "#! /usr/bin/env sh -e\necho"
  abs: "#!/usr/local/bin/nu --stdin\n1"
  sh: "#!/bin/sh\necho"
  body: "#!/bin/sh\n#!/bin/bash in the body"
  stub: "#!/bin/sh\nexec ruby -x \"$0\"\n#!/usr/bin/env nu\n1"
  missing: "#!/usr/bin/nonexistent\n"
}
for c in ($cases | transpose name text) { $c.text | save -f $"($dir)/($c.name)"; ^chmod +x $"($dir)/($c.name)" }
let sh = (which sh | get 0.path); let nubin = (which nu | where type == external | get 0.path)
fix-shebangs $dir
let got = {|n| open --raw $"($dir)/($n)" }
assert "env" ((do $got env) == $"#!($sh)\necho")
assert "escript: no extra line" ((do $got abs | lines | length) == 2)
assert "arguments kept" ((do $got args | lines | first) == $"#!($sh) -e")
assert "absolute" ((do $got abs | lines | first) == $"#!($nubin) --stdin")
assert "/bin/sh stays" ((do $got sh) == $cases.sh)
assert "absolute only on the first line" ((do $got body) == $cases.body)
assert "env on any line" ((do $got stub | lines | get 2) == $"#!($nubin)")
assert "not on PATH: untouched" ((do $got missing) == $cases.missing)
^sh $"($dir)/args"
# written by a build system after prepare (pyapp entry points): not prepare's to undo
$"#!($sh)\nimport sys" | save -f $"($dir)/generated"
fix-shebangs $dir --undo
for n in [env args abs stub] { assert $"undo ($n)" ((do $got $n) == ($cases | get $n)) }
assert "generated stays" ((do $got generated) == $"#!($sh)\nimport sys")
done
