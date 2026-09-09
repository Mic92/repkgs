{ package }:
package {
  name = "findutils";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--without-selinux"
    "--localstatedir=/tmp" # locate's default db dir. install-data-hook mkdirs it
  ];
  tests.run = false; # dejagnu + python
  bin = [
    "find"
    "xargs"
  ];
}
