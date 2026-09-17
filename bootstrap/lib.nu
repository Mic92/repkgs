# Helpers shared by all bootstrap recipes. Only nu builtins + clang, llvm-ar, bsdtar, toybox from PATH.

export use ../builder/glob.nu *
export use ../builder/log.nu *

# parallelism granted by Nix (NIX_BUILD_CORES, 0 = all)
export def cores []: nothing -> int {
  let n = ($env.NIX_BUILD_CORES? | default "1" | into int)
  if $n == 0 { sys cpu | length } else { $n }
}

# Run an external command, echoing the command line first, stdout/stderr straight to the build
# log (`complete` would swallow stderr of a child that dies by signal: nu raises before returning
# it). Takes the whole argv so callers can spread a list that includes the program.
export def --wrapped x [...argv: string]: [nothing -> nothing, string -> nothing] {
  print -e $"+ ($argv | str join ' ')"
  ^($argv | first) ...($argv | skip 1)
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

# Copy the files under `from` matching `pattern` to `to`, keeping relative paths. open|save, not
# cp: 4x faster in nu for many small files, and modes from the store are not wanted anyway
export def copy-tree [from: path, to: path, pattern: string = "**/*"]: nothing -> nothing {
  let from = ($from | path expand)
  let files = (files --no-symlink $"($from)/($pattern)" | each {|f| {src: $f, dest: $"($to)/($f | path relative-to $from)"} })
  # directories first and once each: concurrent mkdir and cp of one dir raced (repkgs#2)
  mkdir ...($files | get dest | path dirname | uniq)
  $files | par-each --threads 4 {|f| open --raw $f.src | save -f $f.dest } | ignore
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

# What a libc (musl, glibc headers stage, or a fetched SDK) tells the toolchain steps after it,
# as files under etc/cc/ so compiler-rt.nu and cc.nu carry no per-libc layout knowledge:
#   include-dirs   header dirs relative to the libc output, one per line (compiler-rt.nu)
#   flags          driver flags with the literal word SYSROOT for the final sysroot (cc.nu).
#                  Absent: the ELF default (--sysroot, our libunwind/libc++)
#   cxxflags       what c++ adds on top. Absent: -stdlib=libc++
export def cc-facts [out: path, facts: record]: nothing -> nothing {
  mkdir $"($out)/etc/cc"
  $facts | items {|k, v| $v | str join "\n" | $in + "\n" | save -f $"($out)/etc/cc/($k)" }
}

export def cc-fact [libc: path, name: string]: nothing -> oneof<list<string>, nothing> {
  let f = $"($libc)/etc/cc/($name)"
  if ($f | path exists) { read-list $f }
}

# What differs per binary format / libc in the llvm recipes, decided once. rt: where the clang
# driver looks for a clang_rt library, relative to the resource dir. ldFlavor/ldEmulation: what
# bin/ld must pass so a bare `ld` behaves as the target's linker (libtool probes `ld --help`)
export def target-profile []: nothing -> record {
  let t = $env.clangTarget
  let cpu = $env.cpu
  match [$env.binfmt $env.libc] {
    ["coff" "mingw"] => {posix: false, pic: [], shared: false, exe: ".exe", lld: "ld.lld", ldFlavor: null
      ldEmulation: ({x86_64: "i386pep", aarch64: "arm64pe"} | get $cpu)
      rt: {|n| $"lib/windows/libclang_rt.($n)-($cpu).a" }
      bfd: ({x86_64: "pe-x86-64", aarch64: "pe-aarch64-little"} | get $cpu)
      dlltoolMachine: ({x86_64: "i386:x86-64", aarch64: "arm64"} | get $cpu)}
    ["coff" _] => {posix: false, pic: [], shared: false, exe: ".exe", lld: "lld-link", ldFlavor: link
      rt: {|n| $"lib/($t)/clang_rt.($n).lib" }}
    ["macho" _] => {posix: true, pic: [-fPIC], shared: true, exe: "", lld: "ld64.lld", ldFlavor: darwin
      rt: {|n| $"lib/darwin/libclang_rt.(if $n == builtins { '' } else { $'($n)_' })osx.a" }}
    _ => {posix: true, pic: [-fPIC], shared: true, exe: "", lld: "ld.lld", ldFlavor: null
      rt: {|n| $"lib/($t)/libclang_rt.($n).a" }}
  }
}

# --target plus the platform's -march/hardening flags (nix/platforms.nix).
export def target []: nothing -> list<string> { [$"--target=($env.clangTarget)"] ++ ($env.flags | split row " ") }

# Compile/link against $env.sysroot with the raw clang (recipes that run before `cc` exists,
# or that build the things `cc` is made of). -unwindlib=none because our clang defaults to
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
