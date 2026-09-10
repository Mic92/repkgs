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
  phases = [
    "cmake.configure"
    "cmake.build"
    "cmake.install"
    {
      # `curl-config --cc` would echo the build compiler's store path
      name = "curl-config";
      run = ''
        let f = $"($c.out)/bin/curl-config"
        let text = (open --raw $f | str replace -r "echo '[^']*/bin/cc'" "echo 'cc'")
        $text | save -f $f
      '';
    }
  ];
  dependencies = [
    pkgs.openssl
    pkgs.zlib
    pkgs.zstd
  ];
  buildDependencies = [ buildPkgs.perl ];
}
