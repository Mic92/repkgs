# bin/erl finds its root from $0, so the tree relocates as installed. Cross wants a bootstrap
# system from buildPkgs first (not done). No wx, odbc, jinterface: toolkits not packaged
{
  package,
  pkgs,
  buildPkgs,
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
  ];
  tests.run = false; # the suites run under ts for hours, tests.version and elixir exercise the install
  patches = [
    ./cstdlib.patch
    ./erl-dirname.patch
  ];
  buildDependencies = [ buildPkgs.perl ]; # erts generates opcode tables with it
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
