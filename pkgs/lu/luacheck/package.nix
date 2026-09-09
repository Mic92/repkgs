# a luarocks application: argparse (pure Lua) and luafilesystem (a C module) from the set
{ package, pkgs }:
package {
  name = "luacheck";
  uses = [ "luarocks" ];
  dependencies = [ pkgs.lua ];
  runtimeDependencies = [ pkgs.lua ];
  tests.version = true;
}
