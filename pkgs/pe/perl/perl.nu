use core.nu *

# perl's Configure is its own script, perl-cross adds cross support on top.
# -Duserelocatableinc: @INC is found relative to the perl binary, so the tree relocates
export def configure []: nothing -> nothing {
  let c = (ctx)
  cd $c.src
  "osvers=\"gnulinux\"\nmyuname=\"pkgs\"\nmyhostname=\"pkgs\"\ncf_by=\"pkgs\"\ncf_time=\"1970-01-01\"\n" | save -f config.over
  let z = (dep-root zlib "Compress::Raw::Zlib links it")
  $"BUILD_ZLIB = False\nINCLUDE = ($z)/include\nLIB = ($z)/lib\nOLD_ZLIB = False\nGZIP_OS_CODE = AUTO_DETECT\nUSE_ZLIB_NG = False\nZLIB_INCLUDE = ($z)/include\nZLIB_LIB = ($z)/lib\n" | save -f cpan/Compress-Raw-Zlib/config.in
  # relocatable @INC starts from $^X, which is argv[0] unless perl can ask the OS. The Linux probe
  # runs `ls -l /proc/self/exe` and looks for "/ls" (ours is .coreutils), the macOS one cannot run
  let self_exe = (match $c.platform.os {
    "linux" => [-Dd_procselfexe=define '-Dprocselfexe="/proc/self/exe"']
    "macos" => [-Dusensgetexecutablepath=define]
    _ => []
  })
  # startperl/perlpath: the scripts perl installs name it by PATH, finish's launchers bind them
  let common = [$"-Dprefix=($c.out)" -Dcc=cc -Uinstallusrbinperl -Dinstallstyle=lib/perl5 -Duserelocatableinc ...$self_exe
    "-Dstartperl=#!/usr/bin/env perl" -Dperlpath=perl
    -Dman1dir=none -Dman3dir=none "-Accflags=-D_GNU_SOURCE -fno-strict-aliasing"]
  if $c.platform.cross {
    x cp -r $"($env.PERL_CROSS)/." .
    x patch -p1 -F0 -i $env.PERL_CROSS_PATCH
    # perl-cross ships one patchset per perl release. A point release it does not know yet
    # gets the previous one's
    let want = $"cnf/diffs/perl5-($c.spec.version)"
    if not ($want | path exists) {
      let have = (ls cnf/diffs | get name | where $it =~ ($c.spec.version | str replace -r '\.\d+$' "" | str replace -a "." '\.') | sort --natural | last)
      cp -r $have $want
    }
    # --sysroot: Errno_pm.PL and h2ph parse the target's C headers from there
    x env AR=llvm-ar RANLIB=llvm-ranlib READELF=llvm-readelf OBJDUMP=llvm-objdump NM=llvm-nm $env.CONFIG_SHELL ./configure $"--target=($c.platform.gnuTriple)" --host-cc=cc-build $"--sysroot=($env.PERL_SYSROOT)" ...$common
  } else {
    x $env.CONFIG_SHELL ./Configure -des ...$common
  }
}

# Config.pm and friends record how perl was built: full paths to the seed's tools, the sysroot,
# dependency dirs. Installed, those are store references to things not there at run time.
# Tool paths become bare names, other foreign store paths are dropped
export def scrub []: nothing -> nothing {
  let c = (ctx)
  let arch = (files $"($c.out)/lib/perl5/5.*/*/Config_heavy.pl" | first | path dirname)
  let foreign = $"\(?:-I|-L|--sysroot=\)?/nix/store/\(?!($c.out | path basename)\)[^'\" ]+ ?"
  # -Duserelocatableinc made every path perl uses `.../..`. Configure still records the literal
  # -Dprefix in config_args and initialinstalllocation (by design, "where it was first
  # installed"): the same notation there
  for f in [$"($arch)/Config.pm" $"($arch)/Config_heavy.pl" $"($arch)/CORE/config.h"] {
    edit $f { tools-by-name | str replace -ar $foreign "" | str replace -a $c.out ".../.." }
  }
  let left = (open --raw $"($arch)/Config_heavy.pl" | lines | where { $in =~ '/nix/store/' and $in !~ $c.out })
  if ($left | is-not-empty) { error make {msg: $"Config_heavy.pl still names foreign store paths: ($left | first)"} }
}
