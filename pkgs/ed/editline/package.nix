{
  package,
}:
package {
  # termios
  platforms.posix = true;
  name = "editline";
  uses = [ "autotools" ];
}
