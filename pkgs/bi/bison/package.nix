{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "bison";
  uses = [ "autotools" ];
  bootstrapTools = true;
  buildDependencies = [ buildPkgs.m4 ];
  dependencies = [ pkgs.m4 ];
  autotools.flags = [ "M4=${pkgs.m4}/bin/m4" ];
  # share/bison and locale via reloc.h. gnulib's --enable-relocatable keeps the configured
  # prefix in the binary to compute the new one from
  patches = [ ./relocatable.patch ];
  tests.separate = true;
  tests.dependencies = [ buildPkgs.perl ]; # autom4te
  # 764: the glr2.cc skeleton reads an uninitialized lookahead, which -ftrivial-auto-var-init
  # turns into a trap. Fixed after 3.8.2
  autotools.makeFlags = [ "TESTSUITEFLAGS=-j$(NIX_BUILD_CORES) 1-763 765-776" ];
  # the .yy.stamp rule touches into a directory only in-tree builds have
  phases.before."autotools.test" = [
    {
      name = "example-dirs";
      run = "mkdir examples/c++/glr";
    }
  ];
}
