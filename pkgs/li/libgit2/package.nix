{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "libgit2";
  uses = [ "cmake" ];
  cmake.defs = {
    CMAKE_C_STANDARD = "23"; # silences -Wc11-extensions build log spam
    BUILD_TESTS = false;
    BUILD_CLI = true;
    REGEX_BACKEND = "pcre2";
    USE_SSH = "exec";
  };
  dependencies = [
    pkgs.openssl
    pkgs.pcre2
    pkgs.zlib
  ];
  # libgit2.pc Requires.private openssl, libpcre2-8, zlib: pkgconf needs them for --cflags too
  exports.propagate = [
    pkgs.openssl
    pkgs.pcre2
    pkgs.zlib
  ];
  buildDependencies = [
    buildPkgs.pkgconf
  ];
  tests.run = false; # slow and require network
}
