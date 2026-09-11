# upstream's std for the target, beside rust-bootstrap's host one when formatelf cross-builds
# (builder/systems/cargo.nu overlays <toolchain>-std). Shares rust-bootstrap's sources.toml
{
  variant,
  pkgs,
  platform,
}:
variant pkgs.rust-bootstrap {
  edit = spec: {
    inherit (spec) name prebuilt;
    source = pkgs.rust-bootstrap.sources.fetch "rust-std-${platform.cpu}";
    phases = [
      {
        name = "install";
        run = ''
          x sh install.sh $"--prefix=($c.out)" --disable-ldconfig
          rm -rf ...(glob $"($c.out)/lib/rustlib/{install.log,uninstall.sh,components,rust-installer-version,manifest-*}")
        '';
      }
    ];
    exports = false;
  };
}
