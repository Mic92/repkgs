{ package }:
package {
  name = "sed";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-acl"
    "--without-selinux"
  ];
  # testsuite wants perl + valgrind bits
  tests.relocated = true;
  tests.run = false;
}
