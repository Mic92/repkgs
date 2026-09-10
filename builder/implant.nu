# `prebuilt = true`: upstream ELF binaries get our dynamic linker, the relocation stub and a
# RUNPATH written into them by formatelf, then pass through reloc-fixup like our own builds.

use core.nu *

# Every dynamically linked ELF under bin/, lib/, libexec/ of `dir` (default $out) gets what our
# linker would have given it:
#   - a RUNPATH over libc and the dependencies' lib dirs, padded so reloc-fixup can rewrite it
#     in place afterwards (the slack sizes match pkgs/ji/jig/src/driver.cc)
#   - for executables also our ld.so as interpreter and the relocation stub as entry point
# The binary keeps a real /proc/self/exe this way, which bun and node need to re-exec.
#
# `dir` is for bindists whose install step runs the binaries from the unpacked tree before they
# reach $out (ghc's `make install` calls the just-installed ghc-pkg). That tree gets interpreter
# and RUNPATH but no stub, since the stub only works after reloc-fixup, which runs over $out.
export def main [c: record, dir?: path]: nothing -> nothing {
  let dir = ($dir | default $c.out)
  let elves = (glob $"($dir)/{bin,lib,libexec}/**/*" | where {|f| ($f | path type) == "file" and (is-elf $f) })
  let interp = $"($c.platform.interp | path dirname)/(1..12 | each { './' } | str join)($c.platform.interp | path basename)"
  let libdirs = [($c.platform.interp | path dirname)] ++ (dep-dirs $c.deps libDirs)
  for f in $elves {
    let headers = (^llvm-readelf --program-headers $f)
    # static executables and object files have nothing to resolve
    if not ($headers | str contains "DYNAMIC ") { continue }
    let dirs = ($libdirs ++ (^formatelf --print-rpath $f | str trim | split row ":" | compact -e))
    let runpath = $"($dirs | str join ':'):/('' | fill -c '_' -w (($dirs | length) * 48 - 1))"
    ^chmod u+w $f
    # shared objects only need the RUNPATH: upstream's is $ORIGIN at best and never has libc
    let stub = (if $dir == $c.out { [--set-entry-stub $c.platform.relocStub] } else { [] })
    let exe = (if ($headers | str contains "INTERP ") { $stub ++ [--set-interpreter $interp] } else { [] })
    x formatelf ...$exe --set-rpath $runpath $f
    note implant ($f | path relative-to $dir)
  }
}
