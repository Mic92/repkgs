# The C++ runtime without cmake: libunwind, libc++abi, libc++ (static + shared) and
# libc++experimental (static). Sources are each project's src/ minus the files cmake would leave
# out for a Linux/ELF/pthread/compiler-rt configuration (`skip`) Flags and __config_site are what
# that cmake configure produces.
use ../../../bootstrap/lib.nu *

# `win`/`elf`: extra skip entries per os. On windows threads are win32 (support/win32 sources in,
# no *_LINK_PTHREAD_LIB) and only static archives are built for now
const LIBS = [
  { name: unwind, dir: "libunwind/src", glob: "*.{cpp,c,S}", skip: [Unwind_AIXExtras.cpp], std: "c++17", so: [-lc]
    flags: [-D_LIBUNWIND_IS_NATIVE_ONLY -fno-exceptions -fno-rtti -fstrict-aliasing], elf: [-D_LIBUNWIND_LINK_DL_LIB -D_LIBUNWIND_LINK_PTHREAD_LIB] }
  # cmake would also pass -DHAVE___CXA_THREAD_ATEXIT_IMPL (its probe is fooled by COMPILER_WORKS=ON);
  # musl lacks that symbol and libc++abi's own fallback is fine on glibc too
  # cxa_noexception.cpp is the -fno-exceptions alternative to cxa_exception/cxa_personality
  { name: "c++abi", dir: "libcxxabi/src", glob: "*.cpp", skip: [cxa_noexception.cpp], win_skip: [cxa_thread_atexit.cpp], std: "c++26", so: [-lunwind -lc]
    flags: [-D_LIBCPP_BUILDING_LIBRARY -D_LIBCXXABI_BUILDING_LIBRARY -DLIBCXX_BUILDING_LIBCXXABI -fstrict-aliasing -fsized-deallocation -Ilibcxx/src], elf: [-D_LIBCXXABI_LINK_PTHREAD_LIB] }
  # new.cpp lives in libc++abi (stdlib_new_delete.cpp) when built against it. int128 builtins come
  # from compiler-rt. libdispatch is the Apple PSTL backend. support/{ibm,win32} are other OSes
  { name: "c++", dir: "libcxx/src", glob: "{*,filesystem/*,ryu/*,pstl/*,support/win32/*}.cpp"
    skip: [new.cpp filesystem/int128_builtins.cpp pstl/libdispatch.cpp], elf_skip: [support/win32/compiler_rt_shims.cpp support/win32/locale_win32.cpp support/win32/support.cpp support/win32/thread_win32.cpp]
    std: "c++26", so: [-lc++abi -lunwind -lc]
    flags: [-D_LIBCPP_BUILDING_LIBRARY -D_LIBCPP_LINK_RT_LIB -D_LIBCPP_REMOVE_TRANSITIVE_INCLUDES -DLIBCXX_BUILDING_LIBCXXABI -DLIBC_NAMESPACE=__llvm_libc_common_utils -fvisibility=hidden -faligned-allocation -fsized-deallocation -Ilibcxx/src -Ilibc], elf: [-D_LIBCPP_LINK_PTHREAD_LIB] }
  { name: "c++experimental", dir: "libcxx/src/experimental", glob: "*.cpp", skip: [], std: "c++26", so: null
    flags: [-D_LIBCPP_BUILDING_LIBRARY -D_LIBCPP_LINK_RT_LIB -D_LIBCPP_REMOVE_TRANSITIVE_INCLUDES -DLIBCXX_BUILDING_LIBCXXABI -D_LIBCPP_ENABLE_EXPERIMENTAL -fvisibility=hidden -faligned-allocation -fsized-deallocation], elf: [-D_LIBCPP_LINK_PTHREAD_LIB] }
]

# libcxx/include/__config_site.in as cmake fills it for: stable ABI v1 namespace __1, pthreads,
# filesystem + localization + unicode + wide chars + tzdb on, std::thread PSTL backend,
# hardening "fast" (4) with the hardening-dependent assertion semantic (2), as libcxx/CMakeLists.txt
# encodes LIBCXX_HARDENING_MODE / LIBCXX_ASSERTION_SEMANTIC
def config-site [libc: string]: nothing -> string {
  let win = ($libc == "mingw")
  $"#ifndef _LIBCPP___CONFIG_SITE
#define _LIBCPP___CONFIG_SITE
#define _LIBCPP_ABI_VERSION 1
#define _LIBCPP_ABI_NAMESPACE __1
#define _LIBCPP_ABI_FORCE_ITANIUM 0
#define _LIBCPP_ABI_FORCE_MICROSOFT 0
#define _LIBCPP_HAS_THREADS 1
#define _LIBCPP_HAS_MONOTONIC_CLOCK 1
#define _LIBCPP_HAS_MUSL_LIBC (if $libc == "musl" { 1 } else { 0 })
#define _LIBCPP_HAS_THREAD_API_PTHREAD 0
#define _LIBCPP_HAS_THREAD_API_EXTERNAL 0
#define _LIBCPP_HAS_THREAD_API_WIN32 (if $win { 1 } else { 0 })
#define _LIBCPP_HAS_THREAD_API_C11 0
#define _LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS 0
#define _LIBCPP_HAS_FILESYSTEM 1
#define _LIBCPP_HAS_RANDOM_DEVICE 1
#define _LIBCPP_HAS_LOCALIZATION 1
#define _LIBCPP_HAS_UNICODE 1
#define _LIBCPP_HAS_WIDE_CHARACTERS 1
#define _LIBCPP_HAS_TIME_ZONE_DATABASE (if $win { 0 } else { 1 })
#define _LIBCPP_INSTRUMENTED_WITH_ASAN 0
#define _LIBCPP_PSTL_BACKEND_STD_THREAD
#define _LIBCPP_HARDENING_MODE_DEFAULT 4
#define _LIBCPP_ASSERTION_SEMANTIC_DEFAULT 2
#define _LIBCPP_LIBC_PICOLIBC 0
#define _LIBCPP_LIBC_NEWLIB 0
#define _LIBCPP_LIBC_LLVM_LIBC 0
#endif
"
}

# include/ as `ninja install` would lay it out: c++/v1 (+ the two generated headers), cxxabi.h, unwind.h & co.
def install-headers [src: path, inc: path]: nothing -> nothing {
  let v1 = $"($inc)/c++/v1"
  mkdir $v1
  x cp -r $"($src)/libcxx/include/." $v1
  rm -f $"($v1)/CMakeLists.txt" $"($v1)/__config_site.in" $"($v1)/module.modulemap.in"
  (config-site $env.libc) | save $"($v1)/__config_site"
  cp $"($src)/libcxx/vendor/llvm/default_assertion_handler.in" $"($v1)/__assertion_handler"
  for h in [cxxabi.h __cxxabi_config.h] { cp $"($src)/libcxxabi/include/($h)" $inc }
  copy-tree $"($src)/libunwind/include" $inc "**/*.h"
}

def main []: nothing -> nothing {
  let out = $env.out
  # libc++ 21 includes llvm-libc's internal headers (libc/shared, from_chars) The rest of the monorepo stays packed
  let src = (unpack llvm libcxx libcxxabi libunwind libc/shared libc/src/__support libc/include libc/hdr runtimes cmake)
  let obj = $"($env.NIX_BUILD_TOP)/obj"
  install-headers $src $"($out)/include"
  mkdir $"($out)/lib"
  cd $src

  let common = (ccflags) ++ [
    -O2 -fPIC -nostdinc++ -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -funwind-tables -DNDEBUG
    -D_LIBCPP_HAS_NO_PRAGMA_SYSTEM_HEADER -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS
    $"-I($out)/include/c++/v1" -Ilibcxxabi/include -Ilibunwind/include -w
  ]
  let link = (ccflags) ++ [-nostdlib++ -shared "-Wl,-z,defs" $"-L($out)/lib"]
  let elf = ($env.os == "linux")

  # objects per library built so far: each static archive carries the layers below it (upstream's
  # LIBCXX{,ABI}_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY), so `-static -lc++` needs no -lc++abi -lunwind
  $LIBS | reduce -f {} {|l, built|
    let std = {|f| if ($f | str ends-with ".cpp") { [$"-std=($l.std)"] } else if ($f | str ends-with ".c") { [-std=c11] } else { [] } }
    let skip = $l.skip ++ (if $elf { $l.elf_skip? | default [] } else { $l.win_skip? | default [] })
    let items = (glob $"($l.dir)/($l.glob)" | each { path relative-to $env.PWD } | sort
      | where {|f| ($f | path relative-to $l.dir) not-in $skip }
      | each {|f| {src: $f, obj: $"($obj)/($l.name)/($f).o", flags: (do $std $f)} })
    say $"lib($l.name): ($items | length) files"
    let objs = (compile ($common ++ $l.flags ++ (if $elf { $l.elf? | default [] } else { [] })) $items)
    let carried = (match $l.name { "c++abi" => [unwind], "c++" => [unwind "c++abi"], _ => [] } | each {|b| $built | get $b } | flatten)
    archive $"($out)/lib/lib($l.name).a" ($objs ++ $carried)
    if $elf and $l.so != null {
      let so = $"lib($l.name).so.1"
      x clang ...$link $"-Wl,-soname,($so)" -o $"($out)/lib/($so).0" ...$objs ...$carried ...$l.so
      x ln -s $"($so).0" $"($out)/lib/($so)"
    }
    $built | insert $l.name $objs
  } | ignore
  if not $elf { return }
  # link-time names. libc++.so.1 carries c++abi and unwind (above), so no INPUT() script as
  # upstream installs: zig's linker resolves script members in its own -L list only
  for l in [unwind "c++abi" "c++"] { x ln -s $"lib($l).so.1" $"($out)/lib/lib($l).so" }
  # rustc's and go's prebuilt std hard-code -lgcc_s for the unwinder. libunwind has the same _Unwind_* ABI
  "INPUT(-lunwind)\n" | save $"($out)/lib/libgcc_s.so"
  x ln -s libunwind.a $"($out)/lib/libgcc_s.a" | ignore
  # GCC-world build files add -latomic for __atomic_* libcalls. compiler-rt's builtins (always
  # linked) provide them, so the name only has to resolve
  "/* compiler-rt builtins */\n" | save $"($out)/lib/libatomic.so"
}
