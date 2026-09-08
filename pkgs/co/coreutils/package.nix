{ package }:
package {
  name = "coreutils";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--disable-nls"
    "--disable-dependency-tracking"
    "--disable-acl"
    "--disable-xattr"
    "--disable-libcap"
    "--without-selinux"
    "--without-openssl"
    "--without-libgmp"
    "--enable-no-install-program=kill,uptime"
    # single multicall binary + symlinks: 1 ELF to relocate instead of 106
    "--enable-single-binary=symlinks"
  ];
  env.FORCE_UNSAFE_CONFIGURE = "1";
  tests.relocated = true;
  tests.run = false; # perl, and many root/tty assumptions
  bin = [
    "ls"
    "cp"
    "install"
    "sort"
  ];
}
