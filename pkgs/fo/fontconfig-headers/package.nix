# The JDK dlopens libfontconfig at run time and only needs its headers to build. Real fontconfig
# (a package of its own once something links it) reads the system's /etc/fonts anyway.
{ package }:
package {
  name = "fontconfig-headers";
  steps = [
    {
      # 2.17 generates fontconfig.h from .h.in for one value, meson.build's cacheversion
      name = "fontconfig.h";
      run = ''
        let v = (open meson.build | parse -r "cacheversion = '(?<v>[0-9]+)'" | first | get v)
        open fontconfig/fontconfig.h.in | str replace "@CACHE_VERSION@" $v | save fontconfig/fontconfig.h
      '';
    }
  ];
  install."include/fontconfig/" = "fontconfig/{fontconfig,fcfreetype,fcprivate}.h";
}
