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
# Idempotent: a second pass over the same files writes the same strings into the same place.
export def main [c: record, dir?: path]: nothing -> nothing {
  let dir = ($dir | default $c.out)
  let interp = $"($c.platform.interp | path dirname)/(1..12 | each { './' } | str join)($c.platform.interp | path basename)"
  let libdirs = [($c.platform.interp | path dirname)] ++ (dep-dirs $c.deps libDirs)
  let stub = (if $dir == $c.out { [--set-entry-stub $c.platform.relocStub] } else { [] })
  files $"($dir)/{bin,lib,libexec}/**/*" | where {|f| is-elf $f } | par-each {|f|
    let headers = (^llvm-readelf --program-headers $f)
    # static executables and object files have nothing to resolve
    if not ($headers | str contains "DYNAMIC ") { return }
    # upstream's own entries ($ORIGIN/..) stay, an earlier pass's padding entry goes
    let dirs = ($libdirs ++ (^formatelf --print-rpath $f | str trim | split row ":") | where { $in =~ '^[/$][^_]' } | uniq)
    let runpath = $"($dirs | str join ':'):/('' | fill -c '_' -w (($dirs | length) * 48 - 1))"
    let exe = (if ($headers | str contains "INTERP ") { $stub ++ [--set-interpreter $interp] } else { [] })
    ^chmod u+w $f
    x formatelf ...$exe --set-rpath $runpath $f
    $f | path relative-to $dir
  } | sort | each {|f| note implant $f }
  null
}
