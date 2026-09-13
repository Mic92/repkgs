{
  package,
  buildPkgs,
}:
package {
  name = "openssl";
  # engines and providers next to the loaded libcrypto (reloc.h) instead of a configured libdir
  patches = [ ./relocatable.patch ];
  cc.cflags = [ "-DOSSL_RELOCATABLE" ];
  uses = [ "make" ];
  # own perl Configure. --openssldir is the §3 ambient path, not a store path
  phases.replace."make.configure" = {
    name = "configure";
    run = ''
      let ktls = (if $c.platform.os == "linux" { [enable-ktls] } else { [] })
      x perl ./Configure $c.platform.opensslTarget $"--prefix=($c.out)" "--libdir=lib" "--openssldir=/etc/ssl" shared no-docs no-tests ...$ktls
    '';
  };
  make.installTarget = [
    "install_sw"
    "install_ssldirs"
  ];
  make.installFlags = [ "OPENSSLDIR=$(prefix)/etc/ssl" ];
  # c_rehash is a perl script: perl would become a runtime dependency
  phases.after."make.install" = [
    {
      name = "no-c_rehash";
      run = "rm ($c.out)/bin/c_rehash";
    }
  ];
  tests.run = false;
  buildDependencies = [ buildPkgs.perl ];
  tests.version = "version";
}
