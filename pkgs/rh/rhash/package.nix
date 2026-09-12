# librhash only. Hand-written configure, not autoconf: own option names, exits on unknown ones
{ package }:
package {
  name = "rhash";
  phases = [
    {
      name = "configure";
      run = ''
        let cross = (if $c.platform.cross { [$"--target=($c.platform.triple)"] } else { [] })
        x (tool sh) ./configure $"--prefix=($c.out)" $"--cc=($env.CC)" --enable-lib-shared --disable-gettext ...$cross
      '';
    }
    {
      name = "build";
      run = ''x make $"-j($c.njobs)" lib-shared'';
    }
    {
      name = "install";
      run = "x make -C librhash install-lib-shared install-lib-headers install-so-link";
    }
  ];
}
