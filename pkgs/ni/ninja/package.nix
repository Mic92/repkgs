{ package }:
package {
  name = "ninja";
  # configure.py needs python, python needs zlib (a cmake package) → cycle. So: every src/*.cc
  # that is not a test, a benchmark, Windows-only, an re2c input or the python browse tool
  steps = [
    {
      name = "build";
      run = ''
        cd $c.build
        let srcs = (glob $"($c.src)/src/*.cc" | where { ($in | path basename) !~ '(_test|_perftest|_bench|\.in|-win32)\.cc$|^(test|browse)\.cc$' })
        let flags = [-O2 -DNDEBUG -fvisibility=hidden -Wno-deprecated -DNINJA_PYTHON="python3"]
        $srcs | par-each {|s| x c++ ...$flags -c $s -o $"($s | path parse | get stem).o" } | ignore
        x c++ ...(glob *.o | sort) -o $"($c.src)/ninja"
      '';
    }
  ];
  install."bin/ninja" = "ninja";
}
