# uptrack hook. builtins-<cpu>[-<os>].txt = the lib/builtins sources cmake would select per target,
# derived from the pinned llvm-project. pkgs/ll/llvm/compiler-rt.nu compiles that list so stage0
# needs no cmake.

# list name -> {triple, cmake system name}
const TARGETS = {
  x86_64: {triple: x86_64-unknown-linux-gnu, system: Linux}
  aarch64: {triple: aarch64-unknown-linux-gnu, system: Linux}
  riscv64: {triple: riscv64-unknown-linux-gnu, system: Linux}
  loongarch64: {triple: loongarch64-unknown-linux-gnu, system: Linux}
  powerpc64le: {triple: powerpc64le-unknown-linux-gnu, system: Linux}
  x86_64-windows: {triple: x86_64-pc-windows-msvc, system: Windows}
  aarch64-windows: {triple: aarch64-pc-windows-msvc, system: Windows}
}

# compiler-rt's Apple path shells out to xcrun and PlistBuddy, so it cannot be configured here.
# What it does to the ELF selection is short (lib/builtins/CMakeLists.txt `if(APPLE)` blocks and
# Darwin-excludes/osx.txt): derive the list instead.
const APPLE = {
  aarch64-macos: {
    from: aarch64
    add: [atomic_flag_clear.c atomic_flag_clear_explicit.c atomic_flag_test_and_set.c
      atomic_flag_test_and_set_explicit.c atomic_signal_fence.c atomic_thread_fence.c]
  }
}

def apple-sources [src: path, linux: list<string>, t: record]: nothing -> list<string> {
  let excludes = (open --raw $"($src)/compiler-rt/lib/builtins/Darwin-excludes/osx.txt" | lines | compact -e)
  $linux ++ $t.add
  | where {|f| ($f | path parse | get stem) not-in $excludes and $f != "enable_execute_stack.c" }
  | sort
  | uniq
}

def --wrapped in-shell [...cmd: string]: nothing -> string {
  let pkgs = [cmake ninja llvmPackages.clang-unwrapped llvmPackages.lld llvmPackages.llvm]
  ^nix-shell -p ...$pkgs --run ($cmd | str join ' ')
}

# Configure lib/builtins for one target and read the source list off ninja's targets.
def builtins-sources [src: path, key: string, t: record]: nothing -> list<string> {
  let cpu = ($key | split row "-" | first)
  let build = $"($src)/build-($key)"
  let flags = [
    -G Ninja
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_ASM_COMPILER=clang
    # cmake's Windows-Clang platform wants an rc and all three languages to agree
    -DCMAKE_RC_COMPILER=llvm-rc
    $"-DCMAKE_C_COMPILER_TARGET=($t.triple)"
    $"-DCMAKE_CXX_COMPILER_TARGET=($t.triple)"
    $"-DCMAKE_ASM_COMPILER_TARGET=($t.triple)"
    -DCMAKE_C_COMPILER_WORKS=ON -DCMAKE_CXX_COMPILER_WORKS=ON
    $"-DCMAKE_SYSTEM_NAME=($t.system)" $"-DCMAKE_SYSTEM_PROCESSOR=($cpu)"
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BUILTINS_HIDE_SYMBOLS=ON
    # as bootstrap builds it: atomic.c in (no libatomic.so), "baremetal" = without the three files
    # that need a hosted libc (emutls, enable_execute_stack, eprintf), crtbegin/crtend separately
    -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=OFF -DCOMPILER_RT_BAREMETAL_BUILD=ON -DCOMPILER_RT_BUILD_CRT=OFF
  ]
  in-shell cmake -S $"($src)/compiler-rt/lib/builtins" -B $build ...$flags $">($build).log 2>&1"

  # every object ninja would build for clang_rt.builtins, mapped back to its source under lib/builtins.
  # aarch64 outline atomics are generated outline_atomic_<op><size>_<model>.S -> "@lse/..."
  let objs = (in-shell ninja -C $build -t targets all
    | lines
    | parse -r '^(?<o>CMakeFiles/clang_rt\.builtins[^:]*\.o(?:bj)?):'
    | get o)
  $objs | each {|o|
    let rel = ($o | str replace -r '^CMakeFiles/[^/]+\.dir/(.*)\.o(bj)?$' '$1')
    if $rel =~ 'outline_atomic_helpers\.dir/' or $rel =~ '/outline_atomic_' {
      $"@lse/($rel | path basename)"
    } else {
      $rel
    }
  } | sort | uniq
}

# files stage: {relative path: content}
export def files [entry: record]: nothing -> record {
  let url = ($entry.sources | where key == default | first | get url)
  let tarball = (^nix store prefetch-file --json $url | from json | get storePath)
  let src = (mktemp -d -t llvm-update.XXXX)
  ^tar -xf $tarball -C $src --strip-components 1 --wildcards "*/compiler-rt" "*/cmake"
  let elf = ($TARGETS | items {|key, t| {k: $key, v: (builtins-sources $src $key $t)} } | transpose -r -d)
  let apple = ($APPLE | items {|key, t| {k: $key, v: (apple-sources $src ($elf | get $t.from) $t)} } | transpose -r -d)
  let out = ($elf | merge $apple | items {|key, files|
    print -e $"  ($key): ($files | length) builtins sources"
    {k: $"builtins-($key).txt", v: (($files | str join "\n") + "\n")}
  } | transpose -r -d)
  rm -rf $src
  $out
}
