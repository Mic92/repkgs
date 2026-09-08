{ package }:
package {
  name = "utf8cpp";
  uses = [ "cmake" ];
  steps = [
    "cmake.configure"
    "cmake.install"
  ]; # header-only
}
