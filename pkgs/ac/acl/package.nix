{ package, pkgs }:
package {
  name = "acl";
  uses = [ "autotools" ];
  dependencies = [ pkgs.attr ];
  tests.run = false; # want users bin and daemon in /etc/passwd
  platforms.os = [ "linux" ];
}
