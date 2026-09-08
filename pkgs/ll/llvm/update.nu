# uptrack hook. builtins-<cpu>.txt = the lib/builtins sources cmake would select per cpu, derived
# from the pinned llvm-project. pkgs/ll/llvm/compiler-rt.nu compiles that list so stage0 needs no cmake.

const CPUS = {x86_64: "x86_64-unknown-linux-gnu", aarch64: "aarch64-unknown-linux-gnu", riscv64: "riscv64-unknown-linux-gnu"
  loongarch64: "loongarch64-unknown-linux-gnu", powerpc64le: "powerpc64le-unknown-linux-gnu"}

def --wrapped in-shell [...cmd: string]: nothing -> string {
  ^nix-shell -p cmake ninja llvmPackages.clang-unwrapped llvmPackages.lld --run ($cmd | str join ' ')
}

# files stage: {relative path: content}
export def files [entry: record]: nothing -> record {
  let url = ($entry.sources | where key == default | first | get url)
  let tarball = (^nix store prefetch-file --json $url | from json | get storePath)
  let src = (mktemp -d -t llvm-update.XXXX)
  ^tar -xf $tarball -C $src --strip-components 1 --wildcards "*/compiler-rt" "*/cmake"
  let out = ($CPUS | items {|cpu, triple|
    let build = $"($src)/build-($cpu)"
    (in-shell cmake -S $"($src)/compiler-rt/lib/builtins" -B $build -G Ninja
      -DCMAKE_C_COMPILER=clang -DCMAKE_ASM_COMPILER=clang
      $"-DCMAKE_C_COMPILER_TARGET=($triple)" $"-DCMAKE_ASM_COMPILER_TARGET=($triple)"
      -DCMAKE_C_COMPILER_WORKS=ON -DCMAKE_SYSTEM_NAME=Linux $"-DCMAKE_SYSTEM_PROCESSOR=($cpu)"
      -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BUILTINS_HIDE_SYMBOLS=ON
      # as bootstrap builds it: atomic.c in (no libatomic.so), "baremetal" = without the three files
      # that need a hosted libc (emutls, enable_execute_stack, eprintf), crtbegin/crtend separately
      -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=OFF -DCOMPILER_RT_BAREMETAL_BUILD=ON -DCOMPILER_RT_BUILD_CRT=OFF
      $">($build).log 2>&1")
    # every object ninja would build for clang_rt.builtins, mapped back to its source under
    # lib/builtins. aarch64 outline atomics are generated outline_atomic_<op><size>_<model>.S -> "@lse/..."
    let objs = (in-shell ninja -C $build -t targets all | lines | parse -r '^(?<o>CMakeFiles/clang_rt\.builtins[^:]*\.o):' | get o)
    let files = ($objs | each {|o|
      let rel = ($o | str replace -r '^CMakeFiles/[^/]+\.dir/(.*)\.o$' '$1')
      if $rel =~ 'outline_atomic_helpers\.dir/' or $rel =~ '/outline_atomic_' { $"@lse/($rel | path basename)" } else { $rel }
    } | sort | uniq)
    print -e $"  ($cpu): ($files | length) builtins sources"
    {k: $"builtins-($cpu).txt", v: (($files | str join "\n") + "\n")}
  } | transpose -r -d)
  rm -rf $src
  $out
}
