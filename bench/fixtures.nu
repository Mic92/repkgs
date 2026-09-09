# Synthetic inputs shaped like what the builder meets; sizes are parameters.

# nested tree, every `script_every`th file an executable env script, a few 2 MiB executables
export def source-tree [dir: path, files: int = 3000, script_every: int = 25]: nothing -> path {
  rm -rf $dir
  for i in 0..<$files {
    let d = $"($dir)/d($i mod 40)/s($i mod 7)"
    mkdir $d
    let f = $"($d)/f($i).txt"
    if $i mod $script_every == 0 {
      "#!/usr/bin/env python3\nprint('hi')\n" | save -f $f
      ^chmod +x $f
    } else if $i mod 500 == 1 {
      0..<2048 | each { "x" | fill -w 1024 -c x } | str join "" | save -f $f
      ^chmod +x $f
    } else {
      $"line ($i)\n" | save -f $f
    }
  }
  $dir
}

# fake store paths with lib*.so and exports.json, each propagating the next `fanout`
export def dep-store [store: path, n: int = 60, fanout: int = 2]: nothing -> list<string> {
  rm -rf $store
  let name = {|i| $"($store)/('' | fill -w 32 -c (char -i (97 + ($i mod 26))))-dep($i)" }
  for i in 0..<$n {
    let p = (do $name $i)
    mkdir $"($p)/include" $"($p)/lib/pkgconfig" $"($p)/share/aclocal"
    for l in [a b c] { "" | save -f $"($p)/lib/lib($l)($i).so" }
    let propagate = (1..$fanout | each {|k| $i + $k } | where $it < $n | each {|j| do $name $j })
    {env: {$"DEP($i)_HOME": "{root}/share"}, propagate: $propagate} | to json | save -f $"($p)/exports.json"
  }
  0..<$n | each {|i| do $name $i }
}

# installed prefix: ELFs and scripts in bin/, ELFs among data files in lib/
export def prefix [out: path, elfs: int = 40, scripts: int = 40, libfiles: int = 300]: nothing -> path {
  rm -rf $out
  mkdir $"($out)/bin" $"($out)/lib/sub"
  let elf = $nu.current-exe
  for i in 0..<$elfs { ^cp $elf $"($out)/bin/prog($i)" }
  for i in 0..<$scripts {
    $"#!/usr/bin/env sh\necho ($i)\n" | save -f $"($out)/bin/script($i)"
    ^chmod +x $"($out)/bin/script($i)"
  }
  for i in 0..<$libfiles {
    if $i mod 10 == 0 { ^cp $elf $"($out)/lib/sub/lib($i).so" } else { $"data ($i)" | save -f $"($out)/lib/sub/f($i).dat" }
  }
  ^chmod -R u+w $out
  $out
}

export def cargo-lock [n: int = 600]: nothing -> string {
  let pkgs = (0..<$n | each {|i|
    $"[[package]]\nname = \"crate($i)\"\nversion = \"1.($i).0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"('' | fill -w 64 -c (($i mod 10) | into string))\"\n"
  })
  (["version = 4\n"] ++ $pkgs | str join "\n")
}

# go.sum plus the matching locks/go.toml record
export def go-sum [n: int = 900]: nothing -> record<sum: string, locks: record> {
  let mods = (0..<$n | each {|i| {path: $"github.com/Org($i mod 50)/mod($i)", version: $"v1.($i).0"} })
  let sum = ($mods | each {|m| $"($m.path) ($m.version) h1:xxx=\n($m.path) ($m.version)/go.mod h1:yyy=" } | str join "\n")
  let sri = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
  let locks = ($mods | each {|m| [$"($m.path)@($m.version)" {mod: $sri, zip: $sri}] } | into record)
  {sum: $sum, locks: {go: $locks}}
}

# uv.lock-shaped record, a third of the edges with markers
export def uv-lock [n: int = 300]: nothing -> record {
  let markers = [
    "python_full_version >= '3.9'"
    "sys_platform == 'win32'"
    "python_full_version < '3.11' and platform_machine != 'wasm32'"
    "(sys_platform == 'darwin' or sys_platform == 'linux') and python_version >= '3.8'"
    "implementation_name == 'pypy'"
  ]
  let packages = (0..<$n | each {|i|
    let deps = ([($i + 1) ($i + 2) ($i * 2 + 3)] | where $it < $n | enumerate | each {|e|
      let d = {name: $"pkg($e.item)"}
      if ($i + $e.index) mod 3 == 0 { $d | insert marker ($markers | get (($i + $e.index) mod ($markers | length))) } else { $d }
    })
    {
      name: $"pkg($i)", version: $"($i).0.1", source: {registry: "https://pypi.org/simple"}, dependencies: $deps
      sdist: {url: $"https://files.pythonhosted.org/pkg($i)-($i).0.1.tar.gz", hash: $"sha256:('' | fill -w 64 -c 'a')"}
      wheels: [
        {url: $"https://files.pythonhosted.org/pkg($i)-($i).0.1-py3-none-any.whl", hash: $"sha256:('' | fill -w 64 -c 'b')"}
        {url: $"https://files.pythonhosted.org/pkg($i)-($i).0.1-cp313-cp313-manylinux_2_17_x86_64.whl", hash: $"sha256:('' | fill -w 64 -c 'c')"}
        {url: $"https://files.pythonhosted.org/pkg($i)-($i).0.1-cp313-cp313-win_amd64.whl", hash: $"sha256:('' | fill -w 64 -c 'd')"}
      ]
    }
  })
  {version: 1, "requires-python": ">=3.12", package: ([{name: project, version: "0", source: {editable: "."}, dependencies: [{name: pkg0} {name: pkg1}]}] ++ $packages)}
}

export def jig-log [file: path, lines: int = 20000]: nothing -> path {
  let kinds = [hit hit hit hit miss-stored plain hit rs-hit]
  0..<$lines | each {|i| $"($kinds | get ($i mod ($kinds | length))) /build/source/f($i).c" }
    | append "gocacheprog gets=100 hits=90 puts=10"
    | str join "\n" | save -f $file
  $file
}
