use core.nu *

# A Lua application or module: `luarocks make` of its rockspec into $out as the one rocks tree,
# dependencies from the set's rock server (fetch.luaRocksSet, locks/luarocks.toml). luarocks'
# bin wrappers start our lua with $out on package.path. C modules compile with the cc on PATH
# (luarocks takes CC from the environment) against the target lua.
def knobs []: nothing -> record<rockspec: any, set: any, flags: list<string>> {
  knobs-for luarocks {rockspec: null, set: null, flags: []}
}

# luarocks writes a per-user cache under HOME
export def --env setup []: nothing -> nothing { $env.HOME = (ctx).build }

# `luarocks.rockspec` when the project has several, else luarocks finds the one
export def build []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  let lua = (dep-root lua "rocks run on the target lua")
  cd (project-dir luarocks)
  x luarocks make --tree $c.out $"--only-server=($k.set)" --deps-mode one --no-doc $"LUA_DIR=($lua)" "CFLAGS=-O2 -fPIC" ...$k.flags ...([$k.rockspec] | compact)
}
