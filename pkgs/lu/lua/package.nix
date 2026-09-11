# PUC Lua, the interpreter luarocks packages run on. 5.4 while most rocks still cap `lua < 5.5`.
# Plain Makefile. The linux target links the binary -Wl,-E so C modules luarocks builds resolve
# the Lua API against it, and LUA_ROOT (package.path's default prefix) becomes $out.
{ package, platform }:
package {
  name = "lua";
  uses = [ "autotools" ];
  autotools.outOfTree = false;
  phases.before."autotools.build" = [
    {
      name = "lua-root";
      run = "cd $c.src; open --raw src/luaconf.h | str replace /usr/local/ $'($c.out)/' | save -f src/luaconf.h";
    }
  ];
  phases.remove = [ "autotools.configure" ];
  autotools.buildTarget = [
    {
      linux = "linux";
      macos = "macosx";
    }
    .${platform.os}
  ];
  autotools.makeFlags = [
    "MYCFLAGS=-fPIC"
    "INSTALL_TOP=$(prefix)"
  ];
  autotools.testTarget = [ "test" ];
  bin = [
    "lua"
    "luac"
  ];
  tests.version = "-v";
}
