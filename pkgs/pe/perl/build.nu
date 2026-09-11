use core.nu *

# Configure is not autoconf (perl-cross adds --host support). userelocatableinc: @INC relative to $^X
export def configure []: nothing -> nothing {
  let c = (ctx)
  cd $c.src
  "osvers=\"gnulinux\"\nmyuname=\"pkgs\"\nmyhostname=\"pkgs\"\ncf_by=\"pkgs\"\ncf_time=\"1970-01-01\"\n" | save -f config.over
  let z = (dep-root zlib "Compress::Raw::Zlib links it")
  $"BUILD_ZLIB = False\nINCLUDE = ($z)/include\nLIB = ($z)/lib\nOLD_ZLIB = False\nGZIP_OS_CODE = AUTO_DETECT\nUSE_ZLIB_NG = False\nZLIB_INCLUDE = ($z)/include\nZLIB_LIB = ($z)/lib\n" | save -f cpan/Compress-Raw-Zlib/config.in
  let common = [$"-Dprefix=($c.out)" -Dcc=cc -Uinstallusrbinperl -Dinstallstyle=lib/perl5 -Duserelocatableinc
    -Dman1dir=none -Dman3dir=none "-Accflags=-D_GNU_SOURCE -fno-strict-aliasing"]
  if $c.platform.cross {
    x cp -r $"($env.PERL_CROSS)/." .
    # a maintenance release perl-cross has no patchset for yet takes the previous one's
    let want = $"cnf/diffs/perl5-($c.spec.version)"
    if not ($want | path exists) {
      let have = (ls cnf/diffs | get name | where $it =~ ($c.spec.version | str replace -r '\.\d+$' "" | str replace -a "." '\.') | sort --natural | last)
      cp -r $have $want
    }
    # --sysroot: Errno_pm.PL and h2ph read target headers from $Config{sysroot}
    x env AR=llvm-ar RANLIB=llvm-ranlib READELF=llvm-readelf OBJDUMP=llvm-objdump NM=llvm-nm $env.CONFIG_SHELL ./configure $"--target=($c.platform.triple)" --host-cc=cc-build $"--sysroot=($env.PERL_SYSROOT)" ...$common
  } else {
    x $env.CONFIG_SHELL ./Configure -des ...$common
  }
}

# the installed Config records seed tools, sysroot and dependency dirs: store references to
# things absent at run time. Tools become bare names, other foreign paths go
export def scrub []: nothing -> nothing {
  let c = (ctx)
  let arch = (glob $"($c.out)/lib/perl5/5.*/*/Config_heavy.pl" | first | path dirname)
  let foreign = $"\(?:-I|-L|--sysroot=\)?/nix/store/\(?!($c.out | path basename)\)[^'\" ]+ ?"
  for f in [$"($arch)/Config.pm" $"($arch)/Config_heavy.pl" $"($arch)/CORE/config.h"] {
    let text = (open --raw $f | str replace -ar '/nix/store/[a-z0-9]{32}-seed[^/]*/bin/' "" | str replace -ar $foreign "")
    chmod u+w $f
    $text | save -f $f
  }
  let left = (open --raw $"($arch)/Config_heavy.pl" | lines | where { $in =~ '/nix/store/' and $in !~ $c.out })
  if ($left | is-not-empty) { error make {msg: $"Config_heavy.pl still names foreign store paths: ($left | first)"} }
}
