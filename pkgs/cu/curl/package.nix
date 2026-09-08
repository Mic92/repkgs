{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "curl";
  uses = [ "cmake" ];
  cmake.defs = {
    CURL_USE_OPENSSL = true;
    CURL_USE_LIBPSL = false;
    CURL_USE_LIBSSH2 = false;
    BUILD_LIBCURL_DOCS = false;
    BUILD_MISC_DOCS = false;
    ENABLE_CURL_MANUAL = false;
    CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
    CURL_CA_PATH = "/etc/ssl/certs";
    CURL_CA_SEARCH_SAFE = true;
  };
  tests.run = false; # needs perl + python impacket + minutes
  dependencies = [
    pkgs.openssl
    pkgs.zlib
    pkgs.zstd
  ];
  buildDependencies = [ buildPkgs.perl ];
  bin = [ "curl" ];
}
