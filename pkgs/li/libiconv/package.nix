# iconv for the libc without one. Elsewhere its iconv.h would shadow libc's
{ package }:
package {
  name = "libiconv";
  uses = [ "autotools" ];
  platforms.os = [ "windows" ];
}
