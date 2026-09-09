# Mozilla's CA roots as shipped by certifi. Dependents get SSL_CERT_FILE pointing at the bundle.
{ package }:
package {
  name = "cacert";
  install."etc/ssl/certs/ca-bundle.crt" = "certifi/cacert.pem";
  exports = {
    libDirs = [ ];
    libs = [ ];
    env.SSL_CERT_FILE = "{root}/etc/ssl/certs/ca-bundle.crt";
  };
}
