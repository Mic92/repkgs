# Upstream's bun binary run under our dynamic linker (`prebuilt`), a build tool for the bun build
# system like `rust` is for cargo. From source later (docs/plan.md).
{
  package,
  platform,
  sources,
}:
package {
  name = "bun";
  source = sources.fetch platform.cpu;
  prebuilt = true;
  steps = [
    {
      name = "install";
      run = ''
        mkdir $"((ctx).out)/bin"
        cp bun $"((ctx).out)/bin/bun"
        ^ln -s bun $"((ctx).out)/bin/bunx"
      '';
    }
  ];
  bin = [ "bun" ];
  tests.version = true;
}
