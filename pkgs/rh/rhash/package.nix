# librhash only. Hand-written configure with its own option names
{ package, platform }:
package {
  name = "rhash";
  uses = [ "make" ];
  make.configureFlags = [
    "--enable-lib-shared"
    "--disable-gettext"
  ]
  ++ (if platform.cross then [ "--target=${platform.triple}" ] else [ ]);
  make.buildTarget = [ "lib-shared" ];
  make.installTarget = [
    "-C"
    "librhash"
    "install-lib-shared"
    "install-lib-headers"
    "install-so-link"
  ];
  tests.run = false;
}
