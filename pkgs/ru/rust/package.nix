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
  # std for every platform the set targets, so cargo.nu can cross-compile with --target
  env.components = toString [
    (sources.fetch "cargo-${platform.cpu}")
    (sources.fetch "rust-std-x86_64")
    (sources.fetch "rust-std-aarch64")
    (sources.fetch "rust-std-riscv64")
    (sources.fetch "rust-std-loongarch64")
    (sources.fetch "rust-std-powerpc64le")
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
        for d in (["."] ++ ($env.components | split row " ")) {
          x sh $"($d)/install.sh" $"--prefix=($c.out)" --disable-ldconfig
        }
        rm -rf $"($c.out)/lib/rustlib/($c.platform.triple)/bin" $"($c.out)/share/doc" $"($c.out)/share/man" $"($c.out)/etc"
        # rustc >= 1.90 links x86_64-linux-gnu through its "self-contained" gcc-ld/ld.lld, build
        # scripts included (no cargo rustflags reach those under --target): make that cc's lld
        let gcc_ld = $"($c.out)/lib/rustlib/($c.platform.triple)/bin/gcc-ld"
        mkdir $gcc_ld
        ^ln -s $"../../../../../../(tool ld | path expand | path relative-to $env.NIX_STORE)" $"($gcc_ld)/ld.lld"
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
