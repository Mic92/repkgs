{ package, buildPkgs }:
package {
  name = "libxcrypt";
  # crypt(3) for a POSIX libc
  platforms.os = [
    "linux"
    "macos"
  ];
  uses = [ "autotools" ];
  autotools.flags = [ "--disable-werror" ]; # -Werror with -Wextra on a newer clang than upstream tests
  buildDependencies = [ buildPkgs.perl ];
}
