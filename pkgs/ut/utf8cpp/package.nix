{ package }:
package {
  name = "utf8cpp";
  uses = [ "cmake" ];
  phases = [
    "cmake.configure"
    "cmake.install"
  ]; # header-only
}
