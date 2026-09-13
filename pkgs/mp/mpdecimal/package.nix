{ package }:
package {
  name = "mpdecimal";
  uses = [ "autotools" ];
  tests.run = false; # `check` wants IBM's decTest files, downloaded by tests/gettests.sh
}
