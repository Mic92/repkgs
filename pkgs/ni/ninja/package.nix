{ package }:
package {
  name = "ninja";
  uses = [ "autotools" ];
  # configure.py needs python, python needs zlib (a cmake package) → cycle. The source list is
  # configure.py's (posix, no browse tool); re2c outputs ship in the tarball
  steps = [
    {
      name = "build";
      run = ''
        cd $c.build
        let names = [depfile_parser lexer build build_log clean clparser debug_flags deps_log disk_interface
          dyndep dyndep_parser edit_distance elide_middle eval_env graph graphviz jobserver json line_printer
          manifest_parser metrics missing_deps parser real_command_runner state status_printer
          string_piece_util util version jobserver-posix subprocess-posix ninja]
        let flags = [-O2 -DNDEBUG -fvisibility=hidden -Wno-deprecated -DNINJA_PYTHON="python3"]
        $names | par-each {|n| x c++ ...$flags -c $"($c.src)/src/($n).cc" -o $"($n).o" } | ignore
        x c++ ...($names | each { $"($in).o" }) -o ninja
      '';
    }
    {
      name = "install";
      run = ''
        mkdir $"($c.out)/bin"
        cp $"($c.build)/ninja" $"($c.out)/bin/ninja"
      '';
    }
  ];
}
