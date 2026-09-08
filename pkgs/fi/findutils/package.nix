{ package }:
package {
  name = "findutils";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
    "--without-selinux"
    "--localstatedir=/tmp" # locate's default db dir. install-data-hook mkdirs it
  ];
  tests.run = false; # dejagnu + python
  bin = [
    "find"
    "xargs"
  ];
}
