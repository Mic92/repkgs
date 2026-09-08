# Upstream's rustc + cargo + rust-std binaries, run under our dynamic linker (`prebuilt`, see
# builder/launchers.nu). A build tool: taken from buildPkgs by the cargo build system, never linked
# into outputs.
{
  package,
  pkgs,
  platform,
  sources,
}:
package {
  name = "rust";
  source = sources.fetch "rustc-${platform.cpu}";
  env.components = toString [
    (sources.fetch "cargo-${platform.cpu}")
    (sources.fetch "rust-std-${platform.cpu}")
  ];
  prebuilt = true;
  dependencies = [
    pkgs.zlib
    pkgs.libgcc-shim
  ];
  steps = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        for t in ($env.components | split row " ") { x bsdtar -xf $t --no-same-owner }
        for d in (["."] ++ (ls | where name =~ '^(cargo|rust-std)-' | get name)) {
          x sh $"($d)/install.sh" $"--prefix=($c.out)" --disable-ldconfig
        }
        # rust-lld and friends: cargo.nu links with cc. etc: bash completions
        rm -rf $"($c.out)/lib/rustlib/($c.platform.triple)/bin" $"($c.out)/share/doc" $"($c.out)/share/man" $"($c.out)/etc"
      '';
    }
  ];
  bin = [
    "rustc"
    "cargo"
  ];
  tests.version = "-V";
  exports = {
    libDirs = [ ];
    libs = [ ];
  };
}
