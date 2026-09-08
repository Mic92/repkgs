{ package }:
package {
  name = "grep";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
    "--disable-perl-regexp"
  ];
  tests.relocated = true;
  tests.run = false; # perl
  steps = [
    "autotools.configure"
    "autotools.build"
    "autotools.install"
    {
      # deprecated sh wrappers whose #! would be the build shell
      name = "drop-egrep";
      run = "rm $\"((ctx).out)/bin/egrep\" $\"((ctx).out)/bin/fgrep\"";
    }
  ];
  bin = [ "grep" ];
}
