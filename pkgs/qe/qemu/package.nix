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
    buildPkgs.ninja
  ];
  steps = [
    {
      name = "configure";
      run = ''
        # the tooling venv group wants setuptools, wheel and pip to install qemu's own python/
        # package, which only the functional tests use
        let deps = (open --raw pythondeps.toml | lines | where { $in !~ '^"(qemu|setuptools|wheel|pip)" =' })
        $deps | str join "\n" | save -f pythondeps.toml
        cd $c.build
        (x (tool sh) $"($c.src)/configure" $"--prefix=($c.out)" --disable-download --without-default-features
          --enable-linux-user --disable-system --disable-tools --disable-docs --disable-werror
          --target-list=aarch64-linux-user,loongarch64-linux-user,ppc64le-linux-user,riscv64-linux-user,x86_64-linux-user $"--python=(which python3 | get 0.path)")
      '';
    }
    {
      name = "build";
      run = "x ninja -C $c.build $\"-j($c.njobs)\"";
    }
    {
      # through ninja: the meson that configured is qemu's vendored one, not ours
      name = "install";
      run = "x ninja -C $c.build install";
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
