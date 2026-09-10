use ../core.nu *

# A Lua application or module: `luarocks make` of its rockspec into $out as the one rocks tree,
# dependencies from the set's rock server (fetch.luaRocksSet, locks/luarocks.toml). luarocks'
# bin wrappers start our lua with $out on package.path. C modules compile with the cc on PATH
# (luarocks takes CC from the environment) against the target lua.
# in the project dir
export def setup []: nothing -> nothing { }

export def workdir []: nothing -> string { project-dir luarocks }

# `luarocks.rockspec` when the project has several, else luarocks finds the one
export def build []: nothing -> nothing {
  let c = (ctx)
  let o = (options luarocks)
  let lua = (dep-root lua "rocks run on the target lua")
  x luarocks make --tree $c.out $"--only-server=($o.deps)" --deps-mode one --no-doc $"LUA_DIR=($lua)" "CFLAGS=-O2 -fPIC" ...$o.flags ...([$o.rockspec] | compact)
}
