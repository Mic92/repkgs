{
  package,
  buildPkgs,
}:
package {
  name = "openssl";
  patches = [ ./relocatable.patch ];
  cc.cflags = [ "-DOSSL_RELOCATABLE" ];
  uses = [ "autotools" ];
  # own perl Configure. --openssldir is the §3 ambient path, not a store path
  phases.replace."autotools.configure" = {
    name = "configure";
    run = ''
      cd $c.build
      let target = ({x86_64: "linux-x86_64", aarch64: "linux-aarch64", riscv64: "linux64-riscv64"} | get ($c.platform.triple | split row '-' | first))
      x perl $"($c.src)/Configure" $target $"--prefix=($c.out)" "--libdir=lib" "--openssldir=/etc/ssl" shared no-docs no-tests enable-ktls
    '';
  };
  phases.replace."autotools.install" = {
    name = "install";
    run = "cd $c.build; x make install_sw install_ssldirs $\"OPENSSLDIR=($c.out)/etc/ssl\"; rm $\"($c.out)/bin/c_rehash\""; # perl script; would make perl a runtime dependency
  };
  phases.remove = [ "autotools.test" ];
  buildDependencies = [ buildPkgs.perl ];
  tests.version = "version";
}
