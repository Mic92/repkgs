# The `cc` package for one platform: the jig binary (built once for the build machine by
# jig.nu, copied here so /proc/self/exe finds this etc/jig.conf), the conf naming
# $env.sysroot and crt_interp.o. From here on packages just say `cc` / `c++`.
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  let out = $env.out
  let sysroot = $env.sysroot
  # absolute seed paths: `cc` must work with an empty PATH, and `clang` on PATH is the cache shim
  let clang = $"($env.seed)/bin/clang"
  let lld = $"($env.seed)/bin/ld.lld"
  let flags = (ccflags | where { $in != "-unwindlib=none" }) ++ [-unwindlib=libunwind $"--ld-path=($lld)"]
  mkdir $"($out)/bin" $"($out)/lib" $"($out)/etc"
  cd $env.NIX_BUILD_TOP

  cp $"($env.prebuilt)/bin/jig" $"($out)/bin/jig"
  # store dirs a depfile can name (sysroot members, seed resource headers): builder/core.nu hands them
  # to the content-identity compile cache as JIG_STORE_ROOTS
  $"($sysroot) ($env.seed) (open --raw $'($sysroot)/roots' | str trim)
" | save $"($out)/etc/roots"
  # no `clang` alias: that name keeps meaning the raw seed compiler, which bootstrap recipes drive themselves
  for n in [cc c++ gcc g++ reloc-fixup gocacheprog rustcwrap] { x ln -s jig $"($out)/bin/($n)" }
  x ln -s $lld $"($out)/bin/ld"
  # CC_FOR_BUILD when cross: jig locates its conf via /proc/self/exe, so symlinks to the native cc suffice
  if "native" in $env { for n in [cc c++] { x ln -s $"($env.native)/bin/($n)" $"($out)/bin/($n)-build" } }

  let conf = {cc: $clang, flags: ($flags | str join " "), cxxflags: "-stdlib=libc++", prefix-map: $"($sysroot)=/sysroot:($out)=/cc"}
  # the ELF link policy (interp via crt_interp.o, $ORIGIN RUNPATHs) keys off `libc`; PE needs none of it
  let elf = (if $env.os == "linux" {
    cp $env.crt_interp crt_interp.c  # compile from cwd: the STT_FILE symbol would otherwise record a store path
    let stubflags = [...(target) -O2 -fPIE -ffreestanding -nostdlib -nostdinc -fno-builtin -fno-stack-protector -fno-asynchronous-unwind-tables]
    x clang ...$stubflags -c crt_interp.c -o $"($out)/lib/crt_interp.o"
    # the same code as a flat blob for `formatelf --set-entry-stub` (builder/finish.nu, prebuilt = "reloc")
    x clang ...$stubflags -DRELOC_STUB -fno-jump-tables -fvisibility=hidden -c crt_interp.c -o reloc_stub.o
    "SECTIONS { . = 0; .text : { KEEP(*(.text.header)) *(.text.entry) *(.text .text.* .rodata .rodata.*) } /DISCARD/ : { *(.dynsym .dynstr .hash .gnu.hash .dynamic .interp .comment .note.* .eh_frame*) } }\n" | save stub.ld
    x $lld -pie --no-dynamic-linker -e __reloc_start -T stub.ld reloc_stub.o -o reloc_stub.elf
    x llvm-objcopy -O binary -j .text reloc_stub.elf $"($out)/lib/reloc_stub.bin"
    {libc: $sysroot, interp: $env.interp, crt: $"($out)/lib/crt_interp.o", runtimes: $"($sysroot)/lib"}
  } else { {} })
  $conf | merge $elf | items {|k, v| $"($k) = ($v)" } | str join "\n" | $in + "\n" | save $"($out)/etc/jig.conf"

  # smoke test through the wrapper. Executed only when the target is the build machine
  let exe = (if $env.os == "windows" { ".exe" } else { "" })
  "#include <stdio.h>\nint main(void) { puts(\"cc ok\"); }\n" | save -f hello.c
  "#include <print>\nint main() { std::println(\"c++ ok\"); }\n" | save -f hello.cc
  x $"($out)/bin/cc" hello.c -o $"hello($exe)"
  x $"($out)/bin/c++" -std=c++23 hello.cc -o $"hello++($exe)"
  if $env.os == "linux" and $env.cpu == ($nu.os-info.arch) { say $"(x ./hello)(x ./hello++)" }
}
