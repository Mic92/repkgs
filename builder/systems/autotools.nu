use ../core.nu *
use ../build-cache.nu
use ./make.nu

# autoconf configure, then make.nu's build/test/install
export const OPTIONS = {
  flags: {default: [], doc: "extra arguments for configure"}
  makeFlags: {default: [], doc: "arguments for every make invocation (build, test, install)"}
  configureScript: {default: configure, doc: "configure script relative to the project"}
  outOfTree: {default: true, doc: "configure from a separate build directory"}
  installFlags: {default: [], doc: "arguments for `make install` only"}
  buildTarget: {default: [], doc: "make goals for build (empty: the makefile's default goal)"}
  testTarget: {default: [check], doc: "make goals for test"}
  installTarget: {default: [install], doc: "make goals for install"}
}

export def --env setup []: nothing -> nothing { make setup }

export def workdir []: nothing -> string { if (options autotools).outOfTree { (ctx).build } else { project-dir autotools } }

# Fixes newer upstreams ship, applied to the generated copies old tarballs carry. Each entry:
# files (glob under the source), the text as shipped, its replacement
const BACKPORTS = [
  [files old new];
  # gnulib gettext.h without NLS: `((void) d, gettext (s))` hides the literal from -Wformat-security
  ["**/gettext.h" "((void) (Domainname), gettext (Msgid))" "gettext (Msgid)"]
  ["**/gettext.h" "((void) (Category), dgettext (Domainname, Msgid))" "dgettext (Domainname, Msgid)"]
  # libtool < 2.5 loses compiler-rt's builtins (___chkstk_ms, __divti3) relinking a C++ library
  # -nostdlib: configure keeps only -l/-L words of `$CC -v`, ltmain drops static archive deplibs
  ["**/configure" "    -L* | -R* | -l*)\n       # Some compilers place" "    -L* | -R* | -l* | */libclang_rt.*.a)\n       # Some compilers place"]
  # config.sub between 2018-05 and 2020-12 validates cpu names and predates loongarch
  ["**/config.sub" "| riscv | riscv32 | riscv64 \\" "| loongarch32 | loongarch64 | riscv | riscv32 | riscv64 \\"]
  ["**/ltmain.sh" "\t    # Linking convenience modules into shared libraries is allowed,\n" "\t    case $deplib in */libgcc*.$libext | */libclang_rt*.$libext) deplibs=\"$deplib $deplibs\"; continue ;; esac\n\t    # Linking convenience modules into shared libraries is allowed,\n"]
]

# mtimes kept: a configure newer than the shipped docs has make regenerate them (flex.info: makeinfo)
def backports [src: string]: nothing -> nothing {
  for b in $BACKPORTS {
    for f in (files $"($src)/($b.files)") {
      let text = (open --raw $f)
      if ($text | str contains $b.old) {
        let mtime = (ls -l $f | first | get modified)
        $text | str replace -a $b.old $b.new | save -f $f
        ^touch -d ($mtime | format date "@%s") $f
      }
    }
  }
}

# configure's INSTALL. Some packages record it in installed files (ruby's rbconfig.rb, python's
# sysconfig): the seed's store path there would be a runtime reference, and a bare `install`
# gets ../ prepended per subdirectory by configure. So INSTALL is a copy in the build directory,
# and unrecord-install-tool rewrites that path to plain `install` in the output afterwards. The
# copy is the seed's static binary (next to this nu), which runs from anywhere
def install-tool []: nothing -> string { $"((ctx).build)/install" }

def unrecord-install-tool [out: string]: nothing -> nothing {
  # grep, not glob+open: one process over the tree instead of nu reading every file
  let files = (^grep -rlFI (install-tool) $out | complete | get stdout | lines)
  for f in $files { edit $f { str replace -a (install-tool) install } }
}

# ./configure. Prefix, cache file and INSTALL through the environment (nix/config.site), so
# configure's recorded argv has no build paths
export def --env configure []: nothing -> nothing {
  let c = (ctx); let o = (options autotools)
  let script = $"(project-dir autotools)/($o.configureScript)"
  # always passed: --build names the build machine, --host the target. Natively they
  # coincide, so configure runs its test programs; when cross they differ and it does not
  let host_flags = [$"--host=($c.platform.gnuTriple)" $"--build=($c.platform.buildTriple)"]
  let cache = $"($c.build)/config.cache"
  let key = (build-cache key autoconf [$script] [...$host_flags ...$o.flags])
  note config.cache (if (build-cache restore $key $cache) { "restored" } else { "cold" })
  backports $c.src
  cp ($nu.current-exe | path dirname | path join install) (install-tool)
  with-env {PKGS_PREFIX: $c.out, PKGS_CONFIG_CACHE: $cache, INSTALL: $"(install-tool) -c"} {
    (x $env.CONFIG_SHELL $script --disable-nls --disable-dependency-tracking --disable-static --enable-shared
      ...$host_flags ...$o.flags)
  }
  build-cache store $key $cache
  if not $c.platform.posix { stub-gnulib-tests (workdir) }
}

# gnulib's own tests: their nanosleep/pthread replacements collide with winpthreads' inline ones
def stub-gnulib-tests [build: string]: nothing -> nothing {
  for mf in (files $"($build)/{gnulib-tests,tests}/Makefile" | where { open --raw $in | str contains "test-nanosleep" }) {
    "all install check clean distclean:\n\t@:\n.PHONY: all install check clean distclean\n" | save -f $mf
    note gnulib-tests $"($mf | path relative-to $build | path dirname): skipped on (ctx).platform.os"
  }
}

export def build []: nothing -> nothing { let o = (options autotools); make run-build $o.makeFlags $o.buildTarget }
export def test []: nothing -> nothing { let o = (options autotools); make run-test $o.makeFlags $o.testTarget }
export def install []: nothing -> nothing {
  let o = (options autotools)
  make run-install ($o.makeFlags ++ $o.installFlags) $o.installTarget
  unrecord-install-tool (ctx).out
}
