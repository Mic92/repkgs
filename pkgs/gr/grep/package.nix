{
  package,
  buildPkgs,
}:
package {
  name = "grep";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [ "--disable-perl-regexp" ];
  # spencer1 feeds patterns through `echo`, and dash's expands backslashes
  autotools.makeFlags = [ "SHELL=$(CONFIG_SHELL)" ];
  tests.separate = true;
  tests.dependencies = [ buildPkgs.perl ];
  phases.after."autotools.install" = [
    {
      # deprecated sh wrappers whose #! would be the build shell
      name = "drop-egrep";
      run = "cd $c.out; rm bin/egrep bin/fgrep";
    }
  ];
}
