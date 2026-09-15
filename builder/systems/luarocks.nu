use ../core.nu *

# A Lua application or module: `luarocks make` of its rockspec into $out as the one rocks tree,
# dependencies from the set's rock server (fetch.luaRocksSet, locks/luarocks.toml). luarocks'
# bin wrappers start our lua with their tree on package.path. C modules compile with the cc on PATH
# (luarocks takes CC from the environment) against the target lua.
export const OPTIONS = {
  rockspec: {default: null, type: string, doc: "rockspec file when the source has several (null: luarocks picks)"}
  flags: {default: [], doc: "extra arguments for luarocks make"}
}

export def setup []: nothing -> nothing { }

export def workdir []: nothing -> string { project-dir luarocks }

# `luarocks.rockspec` when the project has several, else luarocks finds the one
export def install []: nothing -> nothing {
  let c = (ctx)
  let o = (options luarocks)
  let lua = (dep-root lua "rocks run on the target lua")
  # luarocks picks link flags for the os it runs on
  let libflag = (if $c.platform.os == "macos" { ["LIBFLAG=-bundle -undefined dynamic_lookup"] } else { [] })
  x luarocks make --tree $c.out $"--only-server=($o.deps)" --deps-mode one --no-doc $"LUA_DIR=($lua)" "CFLAGS=-O2 -fPIC" ...$libflag ...$o.flags ...([$o.rockspec] | compact)
  # the bin wrappers name luarocks' own config dir (a build tool, nothing reads it at run time)
  # and the tree by absolute path: the tree is where the wrapper is
  for f in (files $"($c.out)/bin/*") {
    edit $f {
      str replace -r "LUAROCKS_SYSCONFDIR='[^']*' " ""
      | str replace "\nexec " "\ntree=$(cd \"${0%/*}/..\" && pwd)\nexec "
      | str replace -a $c.out "'\"$tree\"'"
    }
  }
}
