# PUC Lua, the interpreter luarocks packages run on. 5.4 while most rocks still cap `lua < 5.5`.
# Plain Makefile. The linux target links the binary -Wl,-E so C modules luarocks builds resolve
# the Lua API against it.
{ package, platform }:
package {
  name = "lua";
  uses = [ "make" ];
  # package.path and cpath default to the prefix of the running lua or liblua ("!/", as on Windows)
  patches = [ ./relocatable.patch ];
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
  bin = [
    "lua"
    "luac"
  ];
  tests.version = "-v";
}
