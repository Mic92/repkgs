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
  tests.run = false; # the suite wants an ssh server (docker)
}
