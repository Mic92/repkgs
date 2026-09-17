{
  package,
  buildPkgs,
}:
package {
  name = "sed";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-acl"
    "--without-selinux"
  ];
  tests.separate = true;
  tests.dependencies = [ buildPkgs.perl ];
}
