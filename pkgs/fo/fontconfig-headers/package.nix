# The JDK dlopens libfontconfig at run time and only needs its headers to build. Real fontconfig
# (a package of its own once something links it) reads the system's /etc/fonts anyway.
{ package }:
package {
  name = "fontconfig-headers";
  install."include/fontconfig/" = "fontconfig/*.h";
}
