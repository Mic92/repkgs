{
  package,
  pkgs,
}:
package {
  name = "libssh2";
  uses = [ "cmake" ];
  cmake.defs = {
    CRYPTO_BACKEND = "OpenSSL";
    ENABLE_ZLIB_COMPRESSION = true;
    BUILD_EXAMPLES = false;
  };
  dependencies = [
    pkgs.openssl
    pkgs.zlib
  ];
  # libssh2.pc Requires.private libcrypto: pkgconf needs it for --cflags too
  exports.propagate = [
    pkgs.openssl
    pkgs.zlib
  ];
  tests.run = false; # the suite wants an ssh server (docker)
}
