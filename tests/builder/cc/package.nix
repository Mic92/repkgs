{ package, pkgs }:
package {
  name = "test-cc";
  version = "1";
  source = ./src;
  phases = [
    {
      name = "build";
      run = ''
        mkdir $"($c.out)/bin" $"($c.out)/lib"
        x cc -shared -fPIC lib.c -o $"($c.out)/lib/libhello.so"
        x cc -c lib.c -o lib.o
        x llvm-ar rc $"($c.out)/lib/libhello.a" lib.o
        x cc main.c $"-L($c.out)/lib" -lhello -o $"($c.out)/bin/hello"
        # what a wheel or bindist ships: DWARF, a build-id, no package note of ours
        x cc -shared -fPIC -Wl,--package-metadata= lib.c -o $"($c.out)/lib/upstream.so"
        ^ln -s $"($c.out)/lib/libhello.so" $"($c.out)/lib/libabs.so"
        touch $"($c.out)/lib/libhello.la"
        # a finished library copied from a dependency (rust-std does that): RUNPATH already $ORIGIN-relative
        cp (files $"(dep-root zlib "copy a finished library")/lib/libz.so.*.*" | first) $"($c.out)/lib/libcopied.so"
      '';
    }
  ];
  dependencies = [ pkgs.zlib ];
  install."share/" = [ "data" ];
  tests.version = "hello";
}
