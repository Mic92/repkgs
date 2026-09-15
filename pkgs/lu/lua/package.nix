# PUC Lua, the interpreter luarocks packages run on. 5.4 while most rocks still cap `lua < 5.5`.
# The Makefile knows linux, macosx and mingw. msvc is lua.nu (what etc/luavs.bat did)
{
  package,
  platform,
  lib,
}:
let
  msvc = platform.abi == "msvc";
  programs = [
    "lua"
    "luac"
  ];
in
package {
  name = "lua";
  # package.path and cpath default to the prefix of the running lua or liblua ("!/", as on Windows)
  patches = [ ./relocatable.patch ];
  bin = programs;
  tests.version = "-v";
  uses = lib.on (!msvc) [ "make" ];
  phases = lib.on msvc [ "lua.msvc" ];
  make = lib.on (!msvc) {
    buildTarget = [
      (lib.per platform.os {
        linux = "linux";
        macos = "macosx";
        windows = "mingw";
      })
    ];
    # -Wl,-E is in the linux target: C modules luarocks builds resolve the Lua API against the binary
    flags = [
      "MYCFLAGS=-fPIC"
      "INSTALL_TOP=$(prefix)"
    ];
    testTarget = [ "test" ];
    inherit programs;
  };
  # the Makefile installs no DLL, msvc has no install step at all
  install = lib.per platform.abi {
    gnu = lib.on (platform.os == "windows") { "bin/" = [ "src/lua54.dll" ]; };
    apple = { };
    msvc = {
      "bin/" = map (p: "src/${p}.exe") programs ++ [ "src/lua54.dll" ];
      "lib/lua54.lib" = "src/lua54.lib";
      "include/" = map (h: "src/${h}") [
        "lua.h"
        "luaconf.h"
        "lualib.h"
        "lauxlib.h"
        "lua.hpp"
      ];
    };
  };
}
