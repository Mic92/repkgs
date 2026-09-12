# Installing a GHC bindist (upstream's for ghc-bootstrap, hadrian's for ghc) into (ctx).out.
use core.nu *
use implant.nu

export const TOOLCHAIN = [CC=cc CXX=c++ LD=ld AR=ar RANLIB=ranlib STRIP=llvm-strip NM=llvm-nm OBJDUMP=llvm-objdump LLC=llc OPT=opt LLVMAS=clang]

# [pattern replacement] pairs applied to each file in place. Literal unless --regex: the
# replacements carry sh `$top`/`${1}` that regex mode would read as capture groups
def rewrite [files: list<path>, pairs: list<list<string>>, --regex (-r)]: nothing -> nothing {
  for f in $files {
    let s = ($pairs | reduce -f (open --raw $f) {|p, s|
      if $regex { $s | str replace -ar $p.0 $p.1 } else { $s | str replace -a $p.0 $p.1 }
    })
    $s | save -f $f
  }
}

# the package db leaves gmp, libffi, curses (and Debian's rts libnuma) to an ambient search
# path: name our lib dirs, then recache
def close-db [c: record, db: path]: nothing -> nothing {
  for l in [[conf dep]; [ghc-bignum gmp] [rts libffi] [rts numactl] [terminfo ncurses]] {
    let root = ($c.deps | where name == $l.dep | get 0?.root)
    if $root != null { rewrite -r (files $"($db)/($l.conf)-*.conf") [['(?m)^((dynamic-)?library-dirs:)' $"${1} ($root)/lib"]] }
  }
  x $"($c.out)/bin/ghc-pkg" recache
}

# from the unpacked bindist in $env.PWD
export def install []: nothing -> nothing {
  let c = (ctx)
  x sh ./configure $"--prefix=($c.out)" ...$TOOLCHAIN
  x make install
  # bin/ wrappers spell out $out: derive it from the script's location (sh builtins, PATH may be empty)
  rewrite (files --no-symlink $"($c.out)/bin/*") [['#!/bin/sh' "#!/bin/sh\ntop=$(cd \"${0%/*}/..\" && pwd)"] [$c.out '$top']]
  close-db $c (files --dirs $"($c.out)/lib/ghc-*/lib/package.conf.d" | first)
}

# from Debian's unpacked .deb in $env.PWD, for platforms upstream has no bindist for
export def install-deb []: nothing -> nothing {
  let c = (ctx)
  rm -f usr/lib/ghc/lib/package.conf.d # a symlink into /var
  # ghc-pkg runs below, before finish: interpreter and RUNPATH now, the stub when finish repeats it
  implant $c $"($c.src)/usr"
  mkdir $"($c.out)/lib"
  cp -r usr/lib/ghc $"($c.out)/lib/ghc"
  cp -r usr/bin $"($c.out)/bin"
  let lib = $"($c.out)/lib/ghc/lib"
  cp -r var/lib/ghc/package.conf.d $"($lib)/package.conf.d"
  rewrite (files $"($lib)/package.conf.d/*.conf") [[/usr/lib/ghc/lib '${pkgroot}']]
  # Debian's tool names (x86_64-linux-gnu-gcc, /usr/bin/x86_64-linux-gnu-ld, llc-21) -> ours
  rewrite -r [$"($lib)/settings"] [
    ['"[^"]*-gcc"' '"cc"'] ['"[^"]*-g\+\+"' '"c++"'] ['"[^"]*-ld"' '"ld"'] ['"[^"]*-ar"' '"ar"'] ['"[^"]*-ranlib"' '"ranlib"']
    ['"(llc|opt)-[0-9]+"' '"$1"'] ['"clang-[0-9]+"' '"clang"']
  ]
  rewrite (files --no-symlink $"($c.out)/bin/*") [
    ['#!/bin/bash' "#!/bin/sh\ntop=$(cd \"${0%/*}/..\" && pwd)"] [/usr/lib/ghc '$top/lib/ghc'] ['"/usr/bin"' '"$top/bin"']
  ]
  close-db $c $"($lib)/package.conf.d"
}
