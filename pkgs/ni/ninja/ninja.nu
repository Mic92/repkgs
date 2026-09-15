use core.nu *

# configure.py needs python, python needs zlib (a cmake package) → cycle, so the source list
# is ours: src/*.cc minus tests, benchmarks, re2c inputs, the python browse tool and the other
# OS's port. Windows also wants the bundled getopt.
export def build []: nothing -> nothing {
  let c = (ctx)
  let windows = $c.platform.os == "windows"

  let other_port = if $windows { "*-posix.cc" } else { "*-win32.cc" }
  let cxx_srcs = (files $"($c.src)/src/*.cc"
    --exclude [*_test.cc *_perftest.cc *_bench.cc *.in.cc test.cc browse.cc $other_port])
  let c_srcs = if $windows { [$"($c.src)/src/getopt.c"] } else { [] }

  let flags = [-O2 -DNDEBUG -fvisibility=hidden -Wno-deprecated '-DNINJA_PYTHON="python3"']
  let flags = $flags ++ (if $windows { [-DNOMINMAX -D_CRT_SECURE_NO_WARNINGS] } else { [] })

  cd $c.build
  let obj = {|src| $"($src | path parse | get stem).o" }
  $cxx_srcs | par-each {|s| x c++ ...$flags -c $s -o (do $obj $s) } | ignore
  $c_srcs | each {|s| x cc ...$flags -c $s -o (do $obj $s) } | ignore
  x c++ ...($cxx_srcs ++ $c_srcs | each $obj) -o $"ninja($c.platform.ext.exe)"
}
