# The `cc` package for one platform: the jig binary (built once for the build machine by
# jig.nu, copied here so /proc/self/exe finds this etc/jig.conf), the conf naming
# $env.sysroot and crt_interp.o. From here on packages just say `cc` / `c++`.
use ../../../bootstrap/lib.nu *

# absolute seed paths: `cc` must work with an empty PATH, and `clang` on PATH is the cache shim
def seed-bin [name: string]: nothing -> string { $"($env.seed)/bin/($name)" }

def lld []: nothing -> string { seed-bin ({elf: "ld.lld", coff: "lld-link"} | get $env.binfmt) }

# What jig prepends for `cc` (flags) and additionally for `c++` (cxxflags). An SDK states its
# own in etc/cc/{flags,cxxflags} (bootstrap/lib.nu cc-facts, merged into the sysroot), SYSROOT
# and LLD standing for the final paths. A libc we built gets the ELF default: --sysroot, our
# compiler-rt, libunwind and libc++
def driver-flags [sysroot: string]: nothing -> record<flags: list<string>, cxxflags: string> {
  let given = (cc-fact $sysroot flags)
  if $given == null {
    return {
      flags: ((ccflags | where { $in != "-unwindlib=none" }) ++ [-unwindlib=libunwind $"--ld-path=(lld)"])
      cxxflags: "-stdlib=libc++"
    }
  }
  let fill = {|w| $w | str replace -a SYSROOT $sysroot | str replace -a LLD (lld) }
  {
    flags: ((target) ++ ($given | each $fill))
    cxxflags: (cc-fact $sysroot cxxflags | default [] | each $fill | str join " ")
  }
}

# The ELF link policy's parts: crt_interp.o (interp relative to the binary) and the same code as a
# flat blob for `formatelf --set-entry-stub` (builder/implant.nu). Returns the conf keys naming them.
def elf-policy [out: string, sysroot: string]: nothing -> record {
  # compile from cwd: the STT_FILE symbol would otherwise record a store path
  cp $env.crt_interp crt_interp.c
  let flags = [...(target) -O2 -fPIE -ffreestanding -nostdlib -nostdinc -fno-builtin -fno-stack-protector -fno-asynchronous-unwind-tables]
  x clang ...$flags -c crt_interp.c -o $"($out)/lib/crt_interp.o"
  x clang ...$flags -DRELOC_STUB -fno-jump-tables -fvisibility=hidden -c crt_interp.c -o reloc_stub.o
  [
    "SECTIONS {"
    "  . = 0;"
    "  .text : { KEEP(*(.text.header)) *(.text.entry) *(.text .text.* .rodata .rodata.*) }"
    "  /DISCARD/ : { *(.dynsym .dynstr .hash .gnu.hash .dynamic .interp .comment .note.* .eh_frame*) }"
    "}"
  ] | str join "\n" | save stub.ld
  x (lld) -pie --no-dynamic-linker -e __reloc_start -T stub.ld reloc_stub.o -o reloc_stub.elf
  x llvm-objcopy -O binary -j .text reloc_stub.elf $"($out)/lib/reloc_stub.bin"
  {libc: $sysroot, interp: $env.interp, crt: $"($out)/lib/crt_interp.o", runtimes: $"($sysroot)/lib"}
}

# hello.c and hello.cc through the finished wrapper. Run only when the target is the build machine
def smoke-test [out: string]: nothing -> nothing {
  let exe = ({elf: "", coff: ".exe"} | get $env.binfmt)
  "#include <stdio.h>\nint main(void) { puts(\"cc ok\"); }\n" | save -f hello.c
  "#include <print>\nint main() { std::println(\"c++ ok\"); }\n" | save -f hello.cc
  x $"($out)/bin/cc" hello.c -o $"hello($exe)"
  x $"($out)/bin/c++" -std=c++23 hello.cc -o $"hello++($exe)"
  if $env.os == "linux" and $env.cpu == $nu.os-info.arch { say $"(x ./hello)(x ./hello++)" }
}

def main []: nothing -> nothing {
  let out = $env.out
  let sysroot = $env.sysroot
  mkdir $"($out)/bin" $"($out)/lib" $"($out)/etc"
  cd $env.NIX_BUILD_TOP

  # bin/: jig under every name a build system may call. No `clang` alias: that name keeps meaning
  # the raw seed compiler, which bootstrap recipes drive themselves
  cp $"($env.prebuilt)/bin/jig" $"($out)/bin/jig"
  for n in [cc c++ gcc g++ reloc-fixup gocacheprog rustcwrap] { x ln -s jig $"($out)/bin/($n)" }
  x ln -s (lld) $"($out)/bin/ld"
  # CC_FOR_BUILD when cross: jig locates its conf via /proc/self/exe, so symlinks to the native cc suffice
  if "native" in $env { for n in [cc c++] { x ln -s $"($env.native)/bin/($n)" $"($out)/bin/($n)-build" } }

  # etc/roots: store dirs a depfile can name (sysroot members, seed resource headers). builder/core.nu
  # hands them to the content-identity compile cache as JIG_STORE_ROOTS
  let members = (if ($"($sysroot)/roots" | path exists) { open --raw $"($sysroot)/roots" | str trim } else { "" })
  $"($sysroot) ($env.seed) ($members)\n" | save $"($out)/etc/roots"

  # etc/jig.conf
  let d = (driver-flags $sysroot)
  let conf = {
    cc: (seed-bin clang)
    binfmt: $env.binfmt
    flags: ($d.flags | str join " ")
    cxxflags: $d.cxxflags
    prefix-map: $"($sysroot)=/sysroot:($out)=/cc"
  }
  let policy = (if $env.binfmt == "elf" { elf-policy $out $sysroot } else { {} })
  $conf | merge $policy | items {|k, v| $"($k) = ($v)" } | str join "\n" | $in + "\n" | save $"($out)/etc/jig.conf"

  smoke-test $out
}
