# bin/erl finds its root from $0, so the tree relocates as installed. A cross build needs a
# native erlang of the same release to compile the .erl files. No wx, odbc, jinterface
{
  package,
  pkgs,
  buildPkgs,
  platform,
  toolchain,
}:
package {
  name = "erlang";
  uses = [ "autotools" ];
  autotools.outOfTree = false;
  autotools.flags = [
    "--enable-kernel-poll"
    "--with-ssl=${pkgs.openssl}"
    "--without-javac"
    "--without-odbc"
    "--without-wx"
    "--disable-parallel-configure"
  ]
  ++ (if platform.cross then [ "erl_xcomp_sysroot=${toolchain.sysroot}" ] else [ ]);
  tests.run = false; # the suites run under ts for hours, tests.version and elixir exercise the install
  patches = [
    ./cstdlib.patch
    ./erl-dirname.patch
  ];
  buildDependencies = [ buildPkgs.perl ] ++ (if platform.cross then [ buildPkgs.erlang ] else [ ]);
  dependencies = [
    pkgs.ncurses
    pkgs.openssl
    pkgs.zlib
  ];
  exports = false;
  bin = [
    "erl"
    "erlc"
    "escript"
  ];
  # the full version is only in releases/<otp major>/OTP_VERSION, which erl reads here
  tests.version = "erl -noshell -eval {ok,V}=file:read_file(filename:join([code:root_dir(),\"releases\",erlang:system_info(otp_release),\"OTP_VERSION\"])),io:put_chars(V),halt().";
  tests.relocated = true;
}
