# PUC Lua, the interpreter luarocks packages run on. 5.4 while most rocks still cap `lua < 5.5`.
# Plain Makefile. The linux target links the binary -Wl,-E so C modules luarocks builds resolve
# the Lua API against it.
{
  package,
  platform,
}:
package (
  {
    name = "lua";
    # package.path and cpath default to the prefix of the running lua or liblua ("!/", as on Windows)
    patches = [ ./relocatable.patch ];
    bin = [
      "lua"
      "luac"
    ];
    tests.version = "-v";
  }
  // (
    if platform.os != "windows" then
      {
        uses = [ "make" ];
        make.buildTarget = [
          {
            linux = "linux";
            macos = "macosx";
          }
          .${platform.os}
        ];
        make.flags = [
          "MYCFLAGS=-fPIC"
          "INSTALL_TOP=$(prefix)"
        ];
        make.testTarget = [ "test" ];
      }
    else
      {
        phases = [ "lua.msvc" ];
        install = {
          "bin/" = [
            "src/lua.exe"
            "src/luac.exe"
            "src/lua54.dll"
          ];
          "lib/lua54.lib" = "src/lua54.lib";
          "include/" = [
            "src/lua.h"
            "src/luaconf.h"
            "src/lualib.h"
            "src/lauxlib.h"
            "src/lua.hpp"
          ];
        };
      }
  )
)
