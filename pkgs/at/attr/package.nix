{ package }:
package {
  name = "attr";
  uses = [ "autotools" ];
  patches = [ ./relocatable.patch ]; # xattr.conf relative to libattr
  tests.run = false; # set user.* xattrs, the sandbox's build directory refuses them
  bin = [
    "getfattr"
    "setfattr"
    "attr"
  ];
  platforms.os = [ "linux" ];
}
