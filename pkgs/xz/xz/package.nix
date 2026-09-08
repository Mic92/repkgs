{ package }:
package {
  name = "xz";
  uses = [ "autotools" ];
  autotools.flags = [
    "--disable-doc"
    "gl_cv_posix_shell=/bin/sh"
  ]; # else configure bakes the build machine's sh into xzgrep & co
}
