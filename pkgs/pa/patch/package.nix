{ package }:
package {
  # gnulib dirent replacement does not build on mingw
  platforms.posix = true;
  name = "patch";
  uses = [ "autotools" ];
  bootstrapTools = true;
  tests.run = false; # ed
}
