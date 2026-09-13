# Upstream's rustc + cargo + rust-std binaries under an ld.so launcher: the stage0 that builds
# `rust`, nothing else depends on it. `prebuilt = "ldso"` rather than the implant because
# formatelf, which does the implanting, needs cargo to exist first.
{
  package,
  pkgs,
  platform,
  sources,
}:
package {
  name = "rust-bootstrap";
  source = "rustc-${platform.cpu}";
  env.components = toString [
    (sources.fetch "cargo-${platform.cpu}")
    (sources.fetch "rust-std-${platform.cpu}")
  ];
  prebuilt = "ldso";
  dependencies = [
    pkgs.zlib
    pkgs.libgcc-shim
  ];
  phases = [
    {
      name = "install";
      run = ''
        for d in (["."] ++ ($env.components | split row " ")) {
          x sh $"($d)/install.sh" $"--prefix=($c.out)" --disable-ldconfig
        }
        rm -rf $"($c.out)/lib/rustlib/($c.platform.triple)/bin" $"($c.out)/etc"
        # install.sh's bookkeeping names the prefix
        rm -f $"($c.out)/lib/rustlib/install.log" ...(files $"($c.out)/lib/rustlib/manifest-*")
        # rustc >= 1.90 links x86_64-linux-gnu through its "self-contained" gcc-ld/ld.lld, build
        # scripts included: make that cc's lld
        let gcc_ld = $"($c.out)/lib/rustlib/($c.platform.triple)/bin/gcc-ld"
        mkdir $gcc_ld
        ^ln -s (tool ld | path expand) $"($gcc_ld)/ld.lld"
      '';
    }
  ];
  bin = [
    "rustc"
    "cargo"
  ];
  tests.version = "-V";
  exports = false;
}
