# compiler-rt without cmake: builtins (per-target file list in $env.list = pkgs/ll/llvm/builtins-*.txt,
# written by the update.nu next to it), and on ELF crtbegin/crtend plus the profile runtime. Flags
# are the ones cmake would use. The output is laid out as a clang resource dir (include/ + lib/) so
# -resource-dir= works.
use ../../../bootstrap/lib.nu *

# Only libc *headers* exist at this point (libc itself links against what is built here). The
# libc names its header dirs in etc/cc/include-dirs (bootstrap/lib.nu cc-facts)
def libc-includes []: nothing -> list<string> {
  let libc = (cc-fact $env.libcHeaders include-dirs | each {|d| $"($env.libcHeaders)/($d)" })
  let linux = (if "linuxHeaders" in $env { [$"($env.linuxHeaders)/include"] } else { [] })
  let dirs = $libc ++ $linux
  # the libc's case-insensitive header overlay (windows-sdk), relative to its own location
  let flags = (cc-fact $env.libcHeaders flags | default [] | str replace SYSROOT $env.libcHeaders)
  let vfs = ($flags | enumerate | where item == "-ivfsoverlay" | each {|e| [-ivfsoverlay ($flags | get ($e.index + 1))] } | flatten)
  [-nostdlibinc] ++ ($dirs | each {|d| [-isystem $d] } | flatten) ++ $vfs
}

# One compile item per list entry. "@lse/outline_atomic_<op><size>_<model>.S" stands for
# aarch64/lse.S built with those three defines (cmake generates the same by symlinking).
def builtin-item [b: string, obj: string, f: string]: nothing -> record {
  let lse = ($f | parse -r '^@lse/outline_atomic_(?<op>[a-z]+)(?<size>[0-9]+)_(?<model>[0-9])\.S$')
  if ($lse | is-not-empty) {
    let l = $lse.0
    return {src: $"($b)/aarch64/lse.S", obj: $"($obj)/($f).o", flags: [$"-DL_($l.op)" $"-DSIZE=($l.size)" $"-DMODEL=($l.model)"]}
  }
  let std = (if ($f | str ends-with ".cpp") { [-std=c++17 -fno-exceptions -fno-rtti -nostdinc++] } else { [-std=gnu11] })
  {src: $"($b)/($f)", obj: $"($obj)/($f).o", flags: $std}
}

# Where each driver looks for the builtins: the per-target runtime dir with lib<name>.a (ELF) or
# <name>.lib (lld-link), and for darwin only ever lib/darwin/libclang_rt.osx.a (fat in Xcode, one arch here)
def builtins-lib [out: string]: nothing -> string {
  match $env.binfmt {
    "elf" => $"($out)/lib/($env.triple)/libclang_rt.builtins.a"
    "coff" => $"($out)/lib/($env.triple)/clang_rt.builtins.lib"
    "macho" => $"($out)/lib/darwin/libclang_rt.osx.a"
  }
}

# ELF only: crtbegin/crtend (vcruntime and libSystem bring their own) and GCC's crt names for
# glibc's Makeconfig, which links them even when configure saw compiler-rt
def elf-extras [src: string, out: string, common: list<string>]: nothing -> nothing {
  let b = $"($src)/compiler-rt/lib/builtins"
  let libdir = $"($out)/lib/($env.triple)"
  let crtflags = [-DCRT_HAS_INITFINI_ARRAY -DEH_USE_FRAME_REGISTRY]
  compile $common [
    {src: $"($b)/crtbegin.c", obj: $"($libdir)/clang_rt.crtbegin.o", flags: $crtflags}
    {src: $"($b)/crtend.c", obj: $"($libdir)/clang_rt.crtend.o", flags: $crtflags}
  ]
  cd $libdir
  for n in [crtbegin.o crtbeginS.o crtbeginT.o] { x ln -s clang_rt.crtbegin.o $n }
  for n in [crtend.o crtendS.o] { x ln -s clang_rt.crtend.o $n }
}

# runtime for -coverage / -fprofile-instr-generate, where clang looks for it per binfmt. On ELF it
# needs kernel headers (mmap flags), so stage1 only
def profile-runtime [src: string, out: string]: nothing -> nothing {
  if $env.binfmt == "elf" and "linuxHeaders" not-in $env { return }
  let p = $"($src)/compiler-rt/lib/profile"
  # *ROCm* is the separate clang_rt.profile_rocm (needs the sanitizer interception layer),
  # WindowsMMap the win32 mmap port
  let skip = (if $env.binfmt == "coff" { "ROCm" } else { "^WindowsMMap|ROCm" })
  let srcs = (glob $"($p)/*.{c,cpp}" | where { ($in | path basename) !~ $skip })
  let has = ({
    elf: [-DCOMPILER_RT_HAS_ATOMICS=1 -DCOMPILER_RT_HAS_FCNTL_LCK=1 -DCOMPILER_RT_HAS_FLOCK=1 -DCOMPILER_RT_HAS_UNAME=1 -fPIC]
    macho: [-DCOMPILER_RT_HAS_ATOMICS=1 -DCOMPILER_RT_HAS_FCNTL_LCK=1 -DCOMPILER_RT_HAS_FLOCK=1 -DCOMPILER_RT_HAS_UNAME=1 -fPIC]
    coff: [-DCOMPILER_RT_HAS_ATOMICS=1]
  } | get $env.binfmt)
  let flags = (target) ++ (libc-includes) ++ [-O2 -nostdinc++ -w $"-I($src)/compiler-rt/include" $"-I($p)"] ++ $has
  let lib = ({
    elf: $"($out)/lib/($env.triple)/libclang_rt.profile.a"
    coff: $"($out)/lib/($env.triple)/clang_rt.profile.lib"
    macho: $"($out)/lib/darwin/libclang_rt.profile_osx.a"
  } | get $env.binfmt)
  let items = ($srcs | each {|f| {src: $f, obj: $"($env.NIX_BUILD_TOP)/obj/profile/($f | path basename).o"} })
  archive $lib (compile $flags $items)
}

def main []: nothing -> nothing {
  let out = $env.out
  let src = (unpack llvm compiler-rt third-party/siphash)
  let b = $"($src)/compiler-rt/lib/builtins"
  let obj = $"($env.NIX_BUILD_TOP)/obj"

  let pic = ({elf: [-fPIC], macho: [-fPIC], coff: []} | get $env.binfmt)
  # no -DCOMPILER_RT_HAS_FLOAT16 on ppc: clang has no _Float16 there (cmake probes the same)
  let percpu = (match $env.cpu {
    "powerpc64le" => []
    "aarch64" => [-DCOMPILER_RT_HAS_FLOAT16 -DENABLE_BAREMETAL_AARCH64_FMV -DHAS_ASM_LSE]
    _ => [-DCOMPILER_RT_HAS_FLOAT16]
  })
  let common = (target) ++ (libc-includes) ++ $pic ++ $percpu ++ [
    -O2 -fno-builtin -fno-lto -fvisibility=hidden -fomit-frame-pointer -ffreestanding
    -DVISIBILITY_HIDDEN $"-I($b)" $"-I($src)/third-party/siphash/include"
  ]

  let items = (read-list $env.list | each {|f| builtin-item $b $obj $f })
  say $"compiler-rt builtins ($env.cpu): ($items | length) objects"
  let lib = (builtins-lib $out)
  mkdir ($lib | path dirname)
  archive $lib (compile $common $items)

  # resource dir = these libs + clang's own intrinsics headers (shipped in the seed)
  copy-tree (^clang --print-resource-dir | str trim | path join include) $"($out)/include"
  if $env.binfmt == "elf" { elf-extras $src $out $common }
  profile-runtime $src $out
}
