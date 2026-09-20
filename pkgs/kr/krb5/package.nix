{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "krb5";
  # the Windows port is a separate nmake build
  platforms.os = [
    "linux"
    "macos"
  ];
  uses = [ "autotools" ];
  autotools.root = "src";
  autotools.outOfTree = false;
  autotools.flags = [
    "--with-crypto-impl=openssl"
    "--sysconfdir=/etc"
    "--localstatedir=/var"
    "--runstatedir=/run"
    # _GNU_SOURCE turns on glibc's const-preserving strchr, which this trips over in many files
    "krb5_cv_cc_flag__dash_Werror_eq_incompatible_dash_pointer_dash_types=no"
  ];
  patches = [
    ./upstream-libdb2-test-dictionary-file.patch
    ./upstream-kpropd-loopback-only-listen.patch
    ./relocatable.patch # plugin dirs, kprop and kdb5_util relative to the library or daemon
  ];
  phases.after."autotools.install" = [
    {
      name = "compile_et-dir";
      run = "edit $\"($c.out)/bin/compile_et\" { str replace $\"DIR=($c.out)\" 'DIR=$(cd \"$(dirname \"$0\")/..\" && pwd -P)' }";
    }
  ];
  tests.parallel = false; # every test directory starts a KDC on the same fixed ports
  buildDependencies = [
    buildPkgs.bison
    buildPkgs.perl
  ];
  dependencies = [ pkgs.openssl ];
}
