{ package }:
package {
  # pwd.h, fnmatch
  platforms.posix = true;
  name = "findutils";
  uses = [ "autotools" ];
  bootstrapTools = true;
  patches = [ ./relocatable.patch ]; # frcode and find next to the script, not under the prefix
  autotools.flags = [
    "--without-selinux"
    "--localstatedir=/tmp" # locate's default db dir. install-data-hook mkdirs it
    "ac_cv_path_SORT=sort" # updatedb would record the build machine's
    "SORT_SUPPORTS_Z=true"
  ];
  tests.run = false; # dejagnu + python
  bin = [
    "find"
    "xargs"
  ];
}
