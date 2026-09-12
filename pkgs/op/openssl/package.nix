{
  package,
  buildPkgs,
}:
package {
  name = "openssl";
  patches = [ ./relocatable.patch ];
  cc.cflags = [ "-DOSSL_RELOCATABLE" ];
  uses = [ "make" ];
  # own perl Configure. --openssldir is the §3 ambient path, not a store path
  phases.replace."make.configure" = {
    name = "configure";
    run = ''
      let target = ({x86_64: "linux-x86_64", aarch64: "linux-aarch64", riscv64: "linux64-riscv64"} | get $c.platform.cpu)
      x perl ./Configure $target $"--prefix=($c.out)" "--libdir=lib" "--openssldir=/etc/ssl" shared no-docs no-tests enable-ktls
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
