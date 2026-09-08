# Mozilla's CA roots as shipped by certifi. Dependents get SSL_CERT_FILE pointing at the bundle.
{ package }:
package {
  name = "cacert";
  steps = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        mkdir $"($c.out)/etc/ssl/certs"
        cp certifi/cacert.pem $"($c.out)/etc/ssl/certs/ca-bundle.crt"
      '';
    }
  ];
  exports = {
    libDirs = [ ];
    libs = [ ];
    env.SSL_CERT_FILE = "{root}/etc/ssl/certs/ca-bundle.crt";
  };
}
