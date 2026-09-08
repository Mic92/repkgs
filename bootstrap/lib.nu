# Helpers shared by all bootstrap recipes. Only nu builtins + the seed (clang, llvm-ar, bsdtar, toybox).

export def say [msg: string]: nothing -> nothing { print -e $"(ansi green)==(ansi reset) ($msg)" }

# parallelism granted by Nix (NIX_BUILD_CORES, 0 = all)
export def cores []: nothing -> int {
  let n = ($env.NIX_BUILD_CORES? | default "1" | into int)
  if $n == 0 { sys cpu | length } else { $n }
}

# Run an external command. On failure raise with its stderr, otherwise return stdout.
# Takes the whole argv so callers can spread a list that includes the program.
export def --wrapped x [...argv: string]: [nothing -> string, string -> string] {
  let r = (^($argv | first) ...($argv | skip 1) | complete)
  if $r.exit_code != 0 {
    error make {msg: $"($argv | first) failed \(($r.exit_code)\): ($argv | last 3 | str join ' ')\n($r.stderr)"}
  }
  $r.stdout
}

# Absolute path of a tool on PATH (configure scripts write it into #! lines, so "sh" is not enough).
export def tool [name: string]: nothing -> path {
  let hits = (which $name)
  if ($hits | is-empty) { error make {msg: $"($name) not on PATH"} }
  $hits | first | get path
}

# Copy the (already unpacked) $env.src to $NIX_BUILD_TOP/<name>, writable. `only` limits it to subdirectories.
export def unpack [name: string, ...only: string]: nothing -> path {
  let dest = $"($env.NIX_BUILD_TOP)/($name)"
  mkdir $dest
  # -p: the store's uniform mtimes keep generated files "newer" than their inputs for make
  if ($only | is-empty) { x cp -rp $"($env.src)/." $dest }
  for d in $only {
    mkdir ($"($dest)/($d)" | path dirname)
    x cp -rp $"($env.src)/($d)" $"($dest)/($d)"
  }
  x chmod -R u+w $dest
  $dest
}

# Copy the files under `from` matching `pattern` to `to`, keeping relative paths.
export def copy-tree [from: path, to: path, pattern: string = "**/*"]: nothing -> nothing {
  let from = ($from | path expand)
  glob $"($from)/($pattern)" | where { ($in | path type) == "file" } | par-each --threads (cores) {|f|
    let dest = $"($to)/($f | path relative-to $from)"
    mkdir ($dest | path dirname)
    cp -f $f $dest
  } | ignore
}

# content-identity compile cache (default.nix `cached`): every store path handed to the recipe, and
# whatever a sysroot links to, is a root that headers in a depfile may resolve into
export-env {
  let store = ($env.NIX_STORE? | default "/nix/store")
  let direct = ($env | values | where {|v| ($v | describe) == "string" and ($v | str contains $"($store)/") })
  let via_sysroot = (if "sysroot" in $env and ($"($env.sysroot)/roots" | path exists) { [(open --raw $"($env.sysroot)/roots")] } else { [] })
  $env.JIG_STORE_ROOTS = ($direct ++ $via_sysroot | str join " ")
}

# Lines of a vendored list file.
export def read-list [file: path]: nothing -> list<string> { open --raw $file | lines | where { $in != "" } }

# --target plus the platform's -march/hardening flags (nix/platforms.nix).
export def target []: nothing -> list<string> { [$"--target=($env.triple)"] ++ ($env.flags | split row " ") }

# Compile/link against $env.sysroot with the raw seed clang (recipes that run before `cc` exists,
# or that build the things `cc` is made of). -unwindlib=none because the seed clang defaults to
# libunwind, which is built last. Plain C needs no unwinder.
export def ccflags []: nothing -> list<string> {
  (target) ++ [$"--sysroot=($env.sysroot)" $"-resource-dir=($env.sysroot)/lib/clang" -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld]
}

# Parallel compile. An item may add per-file `flags`. Returns the object paths.
export def compile [common: list<string>, items: list<record<src: string, obj: string>>]: nothing -> list<string> {
  let failed = ($items | par-each --threads (cores) {|it|
    mkdir ($it.obj | path dirname)
    let r = (^clang ...$common ...($it.flags? | default []) -c $it.src -o $it.obj | complete)
    if $r.exit_code != 0 { {src: $it.src, err: $r.stderr} }
  } | compact)
  if ($failed | is-not-empty) {
    for f in ($failed | first 3) { print -e $"--- ($f.src)\n($f.err)" }
    error make {msg: $"($failed | length) of ($items | length) compiles failed"}
  }
  $items | get obj
}

# Static archive via response file (libc.a exceeds argv limits).
export def archive [out: path, objs: list<string>]: nothing -> nothing {
  let rsp = $"($out).rsp"
  $objs | str join "\n" | save -f $rsp
  rm -f $out
  x llvm-ar rcsD $out $"@($rsp)"
  rm $rsp
}
