# bin/{elixir,elixirc,iex} are sh scripts (dirname, readlink, sed) that exec erl: those are
# the dependencies
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "elixir";
  uses = [ "make" ];
  make.testTarget = [ "test_stdlib" ]; # test_mix wants git and network
  buildDependencies = [ buildPkgs.erlang ];
  dependencies = [
    pkgs.erlang
    pkgs.coreutils
    pkgs.sed
  ];
  exports = false;
  # yecc wrote the build erlang's include path into the parser beams
  env.ERL_COMPILER_OPTIONS = "deterministic";
  bin = [
    "elixir"
    "elixirc"
    "mix"
    "iex"
  ];
  tests.relocated = true;
}
