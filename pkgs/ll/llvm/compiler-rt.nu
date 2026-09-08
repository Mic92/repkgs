# compiler-rt without cmake: builtins (per-arch file list in $env.list = pkgs/ll/llvm/builtins-<cpu>.txt,
# written by the update.nu next to it), crtbegin/crtend, and the profile runtime. Flags are the ones cmake would use.
# The output is laid out as a clang resource dir (include/ + lib/<triple>/) so -resource-dir= works.
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  let src = (unpack llvm compiler-rt third-party/siphash)
  let b = $"($src)/compiler-rt/lib/builtins"
  let obj = $"($env.NIX_BUILD_TOP)/obj"
  let libdir = $"($out)/lib/($env.triple)"

  # only libc *headers* exist at this point (libc itself links against what is built here)
  let sys = [-nostdlibinc -isystem $"($env.libcHeaders)/include"] ++ (if "linuxHeaders" in $env { [-isystem $"($env.linuxHeaders)/include"] } else { [] })
  let common = (target) ++ $sys ++ [
    -O2 -fPIC -fno-builtin -fno-lto -fvisibility=hidden -fomit-frame-pointer -ffreestanding
    -DVISIBILITY_HIDDEN -DCOMPILER_RT_HAS_FLOAT16 $"-I($b)" $"-I($src)/third-party/siphash/include"
  ] ++ (if $env.cpu == "aarch64" { [-DENABLE_BAREMETAL_AARCH64_FMV -DHAS_ASM_LSE] } else { [] })

  # list entries "@lse/outline_atomic_<op><size>_<model>.S" mean: aarch64/lse.S with those three defines
  let items = (read-list $env.list | each {|f|
    let lse = ($f | parse -r '^@lse/outline_atomic_(?<op>[a-z]+)(?<size>[0-9]+)_(?<model>[0-9])\.S$')
    if ($lse | is-empty) { {src: $"($b)/($f)", obj: $"($obj)/($f).o", flags: (if ($f | str ends-with ".cpp") { [-std=c++17 -fno-exceptions -fno-rtti -nostdinc++] } else { [-std=gnu11] })} } else {
      {src: $"($b)/aarch64/lse.S", obj: $"($obj)/($f).o", flags: [$"-DL_($lse.0.op)" $"-DSIZE=($lse.0.size)" $"-DMODEL=($lse.0.model)"]}
    }
  })
  say $"compiler-rt builtins ($env.cpu): ($items | length) objects"
  mkdir $libdir
  archive $"($libdir)/libclang_rt.builtins.a" (compile $common $items)

  # resource dir = these libs + clang's own intrinsics headers (shipped in the seed)
  copy-tree (^clang --print-resource-dir | str trim | path join include) $"($out)/include"
  # ELF only: crtbegin/crtend (mingw-w64's CRT brings its own), the profile runtime, GCC crt names
  if $env.os != "linux" { return }

  let crtflags = [-DCRT_HAS_INITFINI_ARRAY -DEH_USE_FRAME_REGISTRY]
  compile $common [
    {src: $"($b)/crtbegin.c", obj: $"($libdir)/clang_rt.crtbegin.o", flags: $crtflags}
    {src: $"($b)/crtend.c", obj: $"($libdir)/clang_rt.crtend.o", flags: $crtflags}
  ]
  # runtime for -coverage / -fprofile-instr-generate. Needs kernel headers (mmap flags), so stage1 only
  if "linuxHeaders" in $env {
    let p = $"($src)/compiler-rt/lib/profile"
    # WindowsMMap is the win32 port; *ROCm* is the separate clang_rt.profile_rocm (needs the sanitizer interception layer)
    let psrcs = (glob $"($p)/*.{c,cpp}" | where { ($in | path basename) !~ "^WindowsMMap|ROCm" })
    let pflags = (target) ++ $sys ++ [-O2 -fPIC -nostdinc++ -w $"-I($src)/compiler-rt/include" $"-I($p)"
      -DCOMPILER_RT_HAS_ATOMICS=1 -DCOMPILER_RT_HAS_FCNTL_LCK=1 -DCOMPILER_RT_HAS_FLOCK=1 -DCOMPILER_RT_HAS_UNAME=1]
    archive $"($libdir)/libclang_rt.profile.a" (compile $pflags ($psrcs | each {|f| {src: $f, obj: $"($obj)/profile/($f | path basename).o"} }))
  }

  # glibc's Makeconfig links GCC's crt names even when configure detected compiler-rt
  cd $libdir
  for n in [crtbegin.o crtbeginS.o crtbeginT.o] { x ln -s clang_rt.crtbegin.o $n }
  for n in [crtend.o crtendS.o] { x ln -s clang_rt.crtend.o $n }
}
