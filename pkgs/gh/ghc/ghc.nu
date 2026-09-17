use core.nu *
use build-cache.nu
use ghc-bindist.nu

def --wrapped hadrian [...args: string]: nothing -> nothing {
  let c = (ctx)
  cd $c.src
  let bin = (^cabal list-bin $"--project-dir=($c.src)/hadrian" ...(options cabal).flags exe:hadrian | str trim)
  x $bin --directory $c.src $"-j($c.njobs)" --docs=none $"--flavour=release+no_profiled_libs+split_sections(if $c.spec.debug { '+debug_info' })" ...$args
}

export def configure []: nothing -> nothing {
  let c = (ctx)
  cd $c.src
  let libs = ([[flag dep inc]; [ffi libffi include] [gmp gmp include] [curses ncurses include/ncursesw]]
    | each {|l| let r = (dep-root $l.dep "ghc links it"); [$"--with-($l.flag)-includes=($r)/($l.inc)" $"--with-($l.flag)-libraries=($r)/lib"] }
    | flatten)
  # no automake for autoreconf's aclocal, and AC_PATH_PROG only takes an absolute preset
  x sh ./configure $"--prefix=($c.out)" --with-system-libffi ...$libs GHC=ghc $"AutoreconfCmd=(tool autoconf)" ...$ghc_bindist.TOOLCHAIN
}

# _build round-trips through jigd. Not keyed on $out, which changes with every recipe edit and
# only matters from the bindist's configure on
def key []: nothing -> string {
  let a = (attrs)
  build-cache key --no-out $"hadrian/($a.src | path basename)" $a.patches
}

export def build []: nothing -> nothing {
  let dir = $"((ctx).src)/_build"
  note hadrian-cache (if (build-cache restore-dir (key) $dir) { "restored" } else { "cold" })
  hadrian binary-dist-dir
  build-cache store-dir (key) $dir
}

export def install []: nothing -> nothing {
  cd (files --dirs $"((ctx).src)/_build/bindist/ghc-*" | first)
  ghc-bindist install
}
