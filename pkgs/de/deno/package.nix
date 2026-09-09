# Upstream's deno binary under our dynamic linker (`prebuilt`), the build tool of the deno build
# system, as bun and rust are. From source (cargo + rusty_v8) later.
{
  package,
  platform,
  sources,
}:
package {
  name = "deno";
  source = sources.fetch platform.cpu;
  prebuilt = true;
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
