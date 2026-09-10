{
  package,
  pkgs,
  sources,
  platform,
}:
package {
  name = "perl";
  dependencies = [ pkgs.zlib ];
  uses = [ "autotools" ];
  bootstrapTools = true;
  # Configure is not autoconf: in-tree, its own flag syntax, no --host (perl-cross for that).
  # userelocatableinc: @INC relative to $^X, so no prefix is compiled in
  autotools.outOfTree = false;
  phases = [
    {
      name = "configure";
      run = ''
        cd $c.src
        $"osvers=\"gnulinux\"\nmyuname=\"pkgs\"\nmyhostname=\"pkgs\"\ncf_by=\"pkgs\"\ncf_time=\"1970-01-01\"\n" | save -f config.over
        let z = ($c.deps | where { ($in.root | path basename) =~ "-zlib$" } | first)
        $"BUILD_ZLIB = False\nINCLUDE = ($z.root)/include\nLIB = ($z.root)/lib\nOLD_ZLIB = False\nGZIP_OS_CODE = AUTO_DETECT\nUSE_ZLIB_NG = False\nZLIB_INCLUDE = ($z.root)/include\nZLIB_LIB = ($z.root)/lib\n" | save -f cpan/Compress-Raw-Zlib/config.in
        let common = [$"-Dprefix=($c.out)" -Dcc=cc -Uinstallusrbinperl -Dinstallstyle=lib/perl5 -Duserelocatableinc
          -Dman1dir=none -Dman3dir=none "-Accflags=-D_GNU_SOURCE -fno-strict-aliasing"
          $"-Dlocincpth=($z.root)/include" $"-Dloclibpth=($z.root)/lib"]
        if $c.platform.cross {
          x cp -r $"($env.PERL_CROSS)/." .
          # perl-cross carries a patchset per perl release; a maintenance release it has not
          # caught up with takes the previous one's
          let want = $"cnf/diffs/perl5-($c.spec.version)"
          if not ($want | path exists) {
            let have = (ls cnf/diffs | get name | where $it =~ ($c.spec.version | str replace -r '\.\d+$' "" | str replace -a "." '\.') | sort --natural | last)
            cp -r $have $want
          }
          # perl-cross looks for <triple>-<tool> unless the environment names one
          x env AR=llvm-ar RANLIB=llvm-ranlib READELF=llvm-readelf OBJDUMP=llvm-objdump NM=llvm-nm $env.CONFIG_SHELL ./configure $"--target=($c.platform.triple)" --host-cc=cc-build ...$common
        } else {
          x $env.CONFIG_SHELL ./Configure -des ...$common
        }
      '';
    }
    "autotools.build"
    "autotools.test"
    "autotools.install"
  ];
  env = if platform.cross then { PERL_CROSS = "${sources.fetch "cross"}"; } else { };
  tests.run = false; # hours; t/ wants a hostname, /etc/protocols, ...
  tests.relocated = true;
}
