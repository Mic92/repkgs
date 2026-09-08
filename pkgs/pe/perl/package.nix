{
  package,
  pkgs,
}:
package {
  name = "perl";
  dependencies = [ pkgs.zlib ];
  uses = [ "autotools" ];
  bootstrapTools = true;
  # Configure is not autoconf: in-tree, its own flag syntax, no --host (cross needs perl-cross).
  # userelocatableinc: @INC relative to $^X, so no prefix is compiled in
  autotools.outOfTree = false;
  steps = [
    {
      name = "configure";
      run = ''
        let c = (ctx)
        cd $c.src
        $"osvers=\"gnulinux\"\nmyuname=\"pkgs\"\nmyhostname=\"pkgs\"\ncf_by=\"pkgs\"\ncf_time=\"1970-01-01\"\n" | save -f config.over
        let z = ($c.deps | where { ($in.root | path basename) =~ "-zlib$" } | first)
        $"BUILD_ZLIB = False\nINCLUDE = ($z.root)/include\nLIB = ($z.root)/lib\nOLD_ZLIB = False\nGZIP_OS_CODE = AUTO_DETECT\nUSE_ZLIB_NG = False\nZLIB_INCLUDE = ($z.root)/include\nZLIB_LIB = ($z.root)/lib\n" | save -f cpan/Compress-Raw-Zlib/config.in
        (x $env.CONFIG_SHELL ./Configure -des $"-Dprefix=($c.out)" -Dcc=cc -Uinstallusrbinperl -Dinstallstyle=lib/perl5
          -Duserelocatableinc -Dman1dir=none -Dman3dir=none "-Accflags=-D_GNU_SOURCE -fno-strict-aliasing"
          $"-Dlocincpth=($z.root)/include" $"-Dloclibpth=($z.root)/lib")
      '';
    }
    "autotools.build"
    "autotools.test"
    "autotools.install"
  ];
  tests.run = false; # hours; t/ wants a hostname, /etc/protocols, ...
  tests.relocated = true;
  bin = [ "perl" ];
}
