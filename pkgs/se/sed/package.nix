{ package }:
package {
  name = "sed";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
    "--disable-acl"
    "--without-selinux"
  ];
  # testsuite wants perl + valgrind bits
  tests.relocated = true;
  tests.run = false;
  bin = [ "sed" ];
}
