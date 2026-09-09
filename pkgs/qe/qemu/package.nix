# qemu user-mode emulators only (cross tests: platform.emulator). System emulation, tools, docs off.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "qemu";
  dependencies = [
    pkgs.glib
    pkgs.zlib
  ];
  buildDependencies = [
    buildPkgs.cpython
    buildPkgs.meson
    buildPkgs.ninja
  ];
  steps = [
    {
      name = "configure";
      run = ''
        cd $c.build
        (x $env.CONFIG_SHELL $"($c.src)/configure" $"--prefix=($c.out)" --disable-download --without-default-features
          --enable-linux-user --disable-system --disable-tools --disable-docs --disable-werror
          --target-list=aarch64-linux-user,loongarch64-linux-user,ppc64le-linux-user,riscv64-linux-user,x86_64-linux-user $"--python=(which python3 | get 0.path)")
      '';
    }
    {
      name = "build";
      run = "x ninja -C $c.build $\"-j($c.njobs)\"";
    }
    {
      name = "install";
      run = "x meson install -C $c.build --no-rebuild";
    }
  ];
  tests.run = false;
  bin = [
    "qemu-aarch64"
    "qemu-loongarch64"
    "qemu-ppc64le"
    "qemu-riscv64"
    "qemu-x86_64"
  ];
}
