# The Hex client as a mix archive under lib/archives (builder/systems/mix.nu: MIX_ARCHIVES)
{
  package,
  buildPkgs,
}:
package {
  name = "hex";
  buildDependencies = [ buildPkgs.elixir ];
  steps = [
    {
      name = "archive";
      run = ''
        load-env {MIX_ENV: "prod", MIX_HOME: $"($c.build)/mix-home", MIX_ARCHIVES: $"($c.out)/lib/archives"}
        x mix compile --no-deps-check
        x mix archive.build -o hex.ez
        mkdir $"($c.out)/lib/archives"
        x mix archive.install --force hex.ez
      '';
    }
  ];
  bin = [ ];
}
