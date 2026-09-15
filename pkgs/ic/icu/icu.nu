use core.nu *

# Cross compiling, configure --with-cross-build wants the *build tree* of a native ICU for its
# data tools. The installed native ICU has the same tools in bin/, so a small tree pointing at
# them stands in: bin/ symlinks plus the two config files the data Makefiles include
export def cross-buildroot []: nothing -> nothing {
  let native = (tool icupkg | path dirname -n 2)
  let root = $"($env.NIX_BUILD_TOP)/native-icu"
  mkdir $"($root)/config" $"($root)/bin" $"($root)/lib"
  for f in (files --any $"($native)/bin/*") { ^ln -s $f $"($root)/bin/($f | path basename)" }
  [
    $"CROSS_ICU_VERSION=((ctx).spec.version)"
    "TOOLEXEEXT="
    "TOOLBINDIR=$(cross_buildroot)/bin"
    "TOOLLIBDIR=$(cross_buildroot)/lib"
    "INVOKE="
    "PKGDATA_INVOKE="
  ] | str join "\n" | save -f $"($root)/config/icucross.mk"
  # empty, so CURR_FULL_DIR stays unset and data/Makefile reads the .res files it just built
  # rather than the native tree's
  "" | save -f $"($root)/config/icucross.inc"
}

# lib/icu/<version>/{Makefile,pkgdata}.inc are for building ICU data packages against this
# install and name the prefix. Make it relative to the including Makefile
export def relative-prefix []: nothing -> nothing {
  let c = (ctx)
  for f in (files $"($c.out)/lib/icu/*/Makefile.inc") {
    edit $f {
      str replace $"prefix = ($c.out)" "prefix = $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../../..)"
      | str replace -r '(?m)^SHELL = .*' "SHELL = /bin/sh"
    }
  }
  for f in (files $"($c.out)/lib/icu/*/pkgdata.inc") {
    edit $f {
      str replace -a $"-I($c.out)/include" "-I$(prefix)/include"
      | str replace -a $"-install_name ($c.out)/" "-install_name $(prefix)/"
      | str replace -a $"-rpath,($c.out)/" "-rpath,$(prefix)/"
    }
  }
}
