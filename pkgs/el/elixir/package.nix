# bin/{elixir,elixirc,iex} are sh scripts (dirname, readlink, sed) that exec erl: those are
# the dependencies
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "elixir";
  uses = [ "autotools" ];
  autotools.outOfTree = false;
  autotools.testTarget = [ "test_stdlib" ]; # test_mix wants git and network
  phases = [
    "autotools.build"
    "autotools.test"
    "autotools.install"
  ];
  buildDependencies = [ buildPkgs.erlang ];
  dependencies = [
    pkgs.erlang
    pkgs.coreutils
    pkgs.sed
  ];
  exports = false;
  bin = [
    "elixir"
    "elixirc"
    "mix"
    "iex"
  ];
  tests.relocated = true;
}
