use core.nu *

# the Makefile knows mingw, not the msvc ABI. What etc/luavs.bat did: a lua54.dll with its
# import library, lua.exe against it, luac.exe static (it uses internals the dll hides)
export def msvc []: nothing -> nothing {
  let c = (ctx)
  cd $"($c.src)/src"
  let objs = (open --raw Makefile | parse -r '(?m)^(?:CORE_O|LIB_O)=\s*(.*)$' | get capture0 | split row -r '\s+' | flatten | where { $in != "" })
  for o in ($objs ++ [lua.o luac.o]) { x cc -O2 -DNDEBUG -DLUA_BUILD_AS_DLL -c ($o | str replace .o .c) -o $o }
  x cc -shared -o lua54.dll ...$objs -Wl,-implib:lua54.lib
  x cc -o lua.exe lua.o lua54.lib
  x cc -o luac.exe luac.o ...$objs
}
