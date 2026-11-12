# librhash only. Hand-written configure with its own option names
{
  package,
  platform,
}:
package {
  name = "rhash";
  uses = [ "make" ];
  # its configure knows linux, darwin, mingw. Not msvc
  platforms.abi = [
    "gnu"
    "apple"
  ];
  make.configureFlags = [
    "--enable-lib-shared"
    "--disable-gettext"
    "--target=${platform.gnuTriple}"
  ];
  make.buildTarget = [ "lib-shared" ];
  make.installTarget = [
    "-C"
    "librhash"
    "install-lib-shared"
    "install-lib-headers"
  ]
  ++ (if platform.os == "windows" then [ ] else [ "install-so-link" ]);
}
