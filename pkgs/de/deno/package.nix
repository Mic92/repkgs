# Upstream's deno binary under our dynamic linker (`prebuilt`), the build tool of the deno build
# system, as bun and rust are. From source (cargo + rusty_v8) later.
{
  package,
  pkgs,
}:
package {
  name = "deno";
  prebuilt = true;
  dependencies = [ pkgs.libgcc-shim ]; # upstream links libgcc_s.so.1 for unwinding
  steps = [
    {
      name = "install";
      run = ''
        mkdir $"((ctx).out)/bin"
        cp deno $"((ctx).out)/bin/deno"
      '';
    }
  ];
  bin = [ "deno" ];
  tests.version = true;
}
