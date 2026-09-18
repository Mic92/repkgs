# The set's compiler: clang, lld and the object tools for all targets against libLLVM.so and
# stage1's glibc and libc++ (bootstrap/default.nix). Shared so plugins can link against it.
use ../../../bootstrap/lib.nu *

# compressed debug sections, both kinds (rustc asks lld for zlib): static, into one prefix cmake finds
def complibs []: nothing -> path {
  let lib = $"($env.NIX_BUILD_TOP)/complibs"
  mkdir $"($lib)/include" $"($lib)/lib" $"($lib)/obj"
  let compile = {|flags: list<string>, srcs: list<path>|
    $srcs | par-each --threads (cores) {|f|
      let obj = $"($lib)/obj/($f | path basename).o"
      ^cc -O2 -fPIC ...$flags -c $f -o $obj
      $obj
    }
  }
  let zstd = $"($env.zstd)/lib"
  archive $"($lib)/lib/libzstd.a" (do $compile [-DZSTD_DISABLE_ASM -DZSTD_LEGACY_SUPPORT=0 -DZSTD_MULTITHREAD] (files $"($zstd)/{common,compress,decompress}/*.c"))
  for h in [zstd.h zdict.h zstd_errors.h] { cp $"($zstd)/($h)" $"($lib)/include/($h)" }
  archive $"($lib)/lib/libz.a" (do $compile [-DHAVE_UNISTD_H -D_LARGEFILE64_SOURCE=1] (files $"($env.zlib)/*.c"))
  for h in [zlib.h zconf.h] { cp $"($env.zlib)/($h)" $"($lib)/include/($h)" }
  $lib
}

def main []: nothing -> nothing {
  let out = $env.out
  let src = (unpack llvm-project llvm clang lld libc cmake third-party libunwind/include runtimes/cmake)
  cd $src
  for p in ($env.patches | split row " ") { x patch -p1 -i $p }
  let complibs = (complibs)
  let sh = (tool sh)
  let build = $"($env.NIX_BUILD_TOP)/build"
  let tools = [llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readelf llvm-readobj llvm-size
    llvm-strings llvm-symbolizer llvm-cxxfilt llvm-cov llvm-profdata llvm-rc llvm-mt llvm-ml llvm-lib llvm-dlltool llvm-windres
    llvm-install-name-tool llvm-lipo llvm-otool dsymutil]
  (x cmake -S llvm -B $build -G "Unix Makefiles"
    $"-DCMAKE_MAKE_PROGRAM=(tool make)" -DCMAKE_BUILD_TYPE=Release $"-DCMAKE_INSTALL_PREFIX=($out)"
    -DCMAKE_C_COMPILER=cc -DCMAKE_CXX_COMPILER=c++ -DCMAKE_AR=(tool llvm-ar) -DCMAKE_RANLIB=(tool llvm-ranlib)
    $"-DCMAKE_PREFIX_PATH=($complibs)" $"-DPython3_EXECUTABLE=(tool python3)"
    "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    "-DLLVM_ENABLE_PROJECTS=clang;lld"
    $"-DLLVM_TARGETS_TO_BUILD=($env.targets)"
    $"-DLLVM_HOST_TRIPLE=($env.clangTarget)" $"-DLLVM_DEFAULT_TARGET_TRIPLE=($env.clangTarget)"
    -DLLVM_LINK_LLVM_DYLIB=ON -DLLVM_BUILD_LLVM_DYLIB=ON -DCLANG_LINK_CLANG_DYLIB=ON
    $"-DLLVM_PARALLEL_LINK_JOBS=([4 (cores)] | math min)"
    -DLLVM_ENABLE_ZLIB=FORCE_ON -DZLIB_USE_STATIC_LIBS=ON -DLLVM_ENABLE_ZSTD=FORCE_ON -DLLVM_USE_STATIC_ZSTD=ON
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF
    -DCLANG_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_DOCS=OFF -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF
    -DCLANG_TOOL_CLANG_REPL_BUILD=OFF -DCLANG_ENABLE_HLSL=OFF
    -DCLANG_DEFAULT_LINKER=lld -DCLANG_DEFAULT_RTLIB=compiler-rt -DCLANG_DEFAULT_UNWINDLIB=libunwind
    -DCLANG_DEFAULT_CXX_STDLIB=libc++ -DCLANG_DEFAULT_OBJCOPY=llvm-objcopy
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON $"-DLLVM_TOOLCHAIN_TOOLS=($tools | str join ';')")
  x make -C $build -j (cores | into string) $"SHELL=($sh)"
  x make -C $build install $"SHELL=($sh)"

  cd $"($out)/bin"
  # offload/sycl wrappers, refactoring tools, python scripts, the C API libraries
  rm -rf ...(files "{clang-*,diagtool,git-clang-format,hmaptool,*-arch}" --exclude [clang-[0-9]*]) ...(files "../lib/lib{clang,LTO,Remarks}.so*") ../share ../include/llvm-c ../include/clang-c
  x llvm-strip --strip-all ...(files --no-symlink $"($out)/{bin/*,lib/*.so*}")
  for n in [ar ranlib nm objcopy objdump strip readelf size strings c++filt addr2line] { x ln -sfn $"llvm-($n)" $n }
  # everything bin/ links, next to it for $ORIGIN/../lib
  for l in (files $"($env.sysroot)/lib/lib{c++,c++abi,unwind}.so.[0-9]") { cp ($l | path expand) $"($out)/lib/" }
  note toolchain (x ./clang --version | lines | first)
}
