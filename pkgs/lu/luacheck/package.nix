# a luarocks application: argparse (pure Lua) and luafilesystem (a C module) from the set
{ package, pkgs }:
package {
  name = "luacheck";
  # luafilesystem's rockspec builds lfs.c the unix way
  platforms.os = [
    "linux"
    "macos"
  ];
  uses = [ "luarocks" ];
  dependencies = [ pkgs.lua ];
  tests.version = true;
}
