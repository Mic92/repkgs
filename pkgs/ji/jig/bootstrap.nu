# jig (src/*.cc + BLAKE3), built once for the build machine against the musl sysroot, static-pie.
# Installed here conf-less as bin/clang and bin/clang++: the compile cache in front of the seed
# clang for the rest of the bootstrap. cc.nu copies the same binary next to a per-platform conf.
# The unit tests run first. A failing assert fails the derivation.
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  let b3 = $"($env.blake3)/c"
  let zstd = $"($env.zstd)/lib"
  let jsn = $"($env.NIX_BUILD_TOP)/json"
  mkdir $jsn $"($out)/bin"
  cp $env.json_hpp $"($jsn)/json.hpp"
  cd $env.NIX_BUILD_TOP

  # BLAKE3: portable C plus the hand-written SIMD for this cpu (x86-64: .S files, aarch64: NEON intrinsics)
  let simd = (match $env.cpu {
    "x86_64" => { {srcs: (glob $"($b3)/blake3_{sse2,sse41,avx2,avx512}_x86-64_unix.S"), defs: []} }
    "aarch64" => { {srcs: [$"($b3)/blake3_neon.c"], defs: [-DBLAKE3_USE_NEON=1]} }
    _ => { {srcs: [], defs: [-DBLAKE3_NO_SSE2 -DBLAKE3_NO_SSE41 -DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512 -DBLAKE3_USE_NEON=0]} }
  })
  let b3objs = (compile ((ccflags) ++ [-O3 -fPIC $"-I($b3)"] ++ $simd.defs) (
    [blake3.c blake3_dispatch.c blake3_portable.c] | each { $"($b3)/($in)" } | append $simd.srcs
    | each {|f| {src: $f, obj: $"obj/($f | path basename).o"} }))
  # libzstd from source: single-threaded, no legacy formats, no asm (huf_decompress_amd64.S wants
  # CET notes we do not emit), no dictBuilder/deprecated
  let zobjs = (compile ((ccflags) ++ [-O2 -fPIC -DZSTD_DISABLE_ASM -DZSTD_LEGACY_SUPPORT=0 -DXXH_NAMESPACE=ZSTD_]) (
    glob $"($zstd)/{common,compress,decompress}/*.c" | each {|f| {src: $f, obj: $"obj/zstd/($f | path basename).o"} }))

  let cxxflags = (ccflags | where { $in != "-unwindlib=none" }) ++ [
    -x c++ -std=c++26 -stdlib=libc++ -O2 -Wall -Wextra -Werror -Wno-unused-command-line-argument
    # every [] / front() / subspan / optional deref is bounds-checked and traps (no exceptions needed)
    -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE -fno-exceptions
    # every integer overflow / truncation / bad shift / OOB array index in our code traps too
    # (BLAKE3 objects are compiled separately without: hashing wraps by design)
    "-fsanitize=signed-integer-overflow,unsigned-integer-overflow,shift,integer-divide-by-zero,implicit-integer-truncation,implicit-integer-sign-change,bounds,pointer-overflow"
    -fsanitize-trap=all -fno-sanitize-recover=all
    $"-DJIG_STORE_DIR=\"($env.storeDir)\"" "-isystem" $b3 "-isystem" $jsn "-isystem" $zstd $"-I($env.jig)"]
  let objs = (compile $cxxflags (glob $"($env.jig)/*.cc" | each {|f| {src: $f, obj: $"obj/($f | path parse | get stem).o"} }))
  let common = ($objs | where { ($in | path basename) not-in [main.o jig_test.o] }) ++ $b3objs ++ $zobjs
  let link = [$"($env.seed)/bin/clang++" ...(ccflags | where { $in != "-unwindlib=none" }) -unwindlib=libunwind -stdlib=libc++ -static-pie]
  x ...$link -o jig_test obj/jig_test.o ...$common
  print -e (x ./jig_test)
  x ...$link -o $"($out)/bin/jig" obj/main.o ...$common
  x llvm-strip $"($out)/bin/jig"
  # symlinks keep /proc/self/exe = jig (no etc/ conf here -> JIG_CC mode) "++" in the name selects C++
  for n in [clang clang++] { x ln -s jig $"($out)/bin/($n)" }
  say $"jig: (ls $"($out)/bin" | length) entries in bin/"
}
