{ package }:
package {
  name = "jansson";
  uses = [ "autotools" ];
  autotools.outOfTree = false; # `make check` writes scripts/clang-format-check.log into the source
}
