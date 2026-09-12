# Installing a GHC bindist (upstream's for ghc-bootstrap, hadrian's for ghc) into (ctx).out.
use core.nu *

export const TOOLCHAIN = [CC=cc CXX=c++ LD=ld AR=ar RANLIB=ranlib STRIP=llvm-strip NM=llvm-nm OBJDUMP=llvm-objdump LLC=llc OPT=opt LLVMAS=clang]

# from the unpacked bindist in $env.PWD
export def install []: nothing -> nothing {
  let c = (ctx)
  x sh ./configure $"--prefix=($c.out)" ...$TOOLCHAIN
  x make install
  # bin/ wrappers spell out $out: derive it from the script's location (sh builtins, PATH may be empty)
  for f in (files --no-symlink $"($c.out)/bin/*") {
    let s = (open --raw $f | str replace '#!/bin/sh' "#!/bin/sh\ntop=$(cd \"${0%/*}/..\" && pwd)" | str replace -a $c.out '$top')
    $s | save -f $f
  }
  # the bindist leaves gmp, libffi and curses to an ambient search path: record where they are
  let db = (files --dirs $"($c.out)/lib/ghc-*/lib/package.conf.d" | first)
  for l in [[conf dep]; [ghc-bignum gmp] [rts libffi] [terminfo ncurses]] {
    let lib = $"(dep-root $l.dep $'($l.conf) links it')/lib"
    for f in (files $"($db)/($l.conf)-*.conf") {
      let s = (open --raw $f | str replace -ar '(?m)^(dynamic-)?library-dirs:' $"${1}library-dirs: ($lib)")
      $s | save -f $f
    }
  }
  x $"($c.out)/bin/ghc-pkg" recache
}
