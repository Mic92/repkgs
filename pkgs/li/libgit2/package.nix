{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "libgit2";
  uses = [ "cmake" ];
  cmake.defs = {
    BUILD_TESTS = false;
    BUILD_CLI = false;
    REGEX_BACKEND = "pcre2";
    USE_SSH = "libssh2";
  };
  dependencies = [
    pkgs.openssl
    pkgs.pcre2
    pkgs.zlib
    pkgs.libssh2
  ];
  buildDependencies = [ buildPkgs.pkgconf ];
  tests.run = false; # slow and wants the network
}
