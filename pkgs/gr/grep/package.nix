{ package }:
package {
  name = "grep";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [ "--disable-perl-regexp" ];
  tests.relocated = true;
  tests.run = false; # perl
  phases.after."autotools.install" = [
    {
      # deprecated sh wrappers whose #! would be the build shell
      name = "drop-egrep";
      run = "rm $\"($c.out)/bin/egrep\" $\"($c.out)/bin/fgrep\"";
    }
  ];
}
