use ../core.nu *
use ../probe-cache.nu
use ./make.nu

# autoconf configure, then make.nu's build/test/install
export def --env setup []: nothing -> nothing { make setup }

export def workdir []: nothing -> string { if (options autotools).outOfTree { (ctx).build } else { project-dir autotools } }

# gnulib's gettext.h without NLS: `((void) d, gettext (s))`. clang sees no string literal
# behind the comma operator and -Werror=format-security rejects every _("...")
def gnulib-gettext-literal [src: string]: nothing -> nothing {
  const FALLBACK = "((void) (Domainname), gettext (Msgid))"
  for f in (files $"($src)/**/gettext.h" | where { open --raw $in | str contains $FALLBACK }) {
    edit $f { str replace -a $FALLBACK "gettext (Msgid)" | str replace -a "((void) (Category), dgettext (Domainname, Msgid))" "dgettext (Domainname, Msgid)" }
  }
}

# configure's INSTALL: the seed's path would be a store reference in rbconfig.rb and python's
# sysconfig, a bare name gets ../ prepended per subdirectory. So a copy in the build dir, and
# after `make install` the files that recorded it say plain `install` (found on PATH)
def install-tool []: nothing -> string { $"((ctx).build)/install" }

def unrecord-install-tool [out: string]: nothing -> nothing {
  # grep, not glob+open: one process over the tree instead of nu reading every file
  let files = (^grep -rlFI (install-tool) $out | complete | get stdout | lines)
  for f in $files { edit $f { str replace -a (install-tool) install } }
}

# ./configure --prefix=$out --enable-shared with cached probe results, no message catalogues,
# no .deps files, --host/--build when cross, `autotools.flags` last
export def --env configure []: nothing -> nothing {
  let c = (ctx); let o = (options autotools)
  let script = $"($c.src)/($o.configureScript)"
  # --host: configure stops running test programs. --build only has to differ from it
  let host_flags = (if $c.platform.cross { [$"--host=($c.platform.configTriple)" "--build=x86_64-build-linux-gnu"] } else { [] })
  let cache = $"($c.build)/config.cache"
  let key = (probe-cache key autoconf [$script])
  note config.cache (if (probe-cache restore $key $cache) { "restored" } else { "cold" })
  gnulib-gettext-literal $c.src
  cp (tool install) (install-tool)
  (x $env.CONFIG_SHELL $script $"--prefix=($c.out)" $"--cache-file=($cache)" --disable-nls --disable-dependency-tracking
    $"INSTALL=(install-tool) -c" --disable-static --enable-shared ...$host_flags ...$o.flags)
  probe-cache store $key $cache
}

export def build []: nothing -> nothing { let o = (options autotools); make run-build $o.makeFlags $o.buildTarget }
export def test []: nothing -> nothing { let o = (options autotools); make run-test $o.makeFlags $o.testTarget }
export def install []: nothing -> nothing {
  let o = (options autotools)
  make run-install ($o.makeFlags ++ $o.installFlags) $o.installTarget
  unrecord-install-tool (ctx).out
}
