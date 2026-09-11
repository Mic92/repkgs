{ package }:
package {
  name = "utf8cpp";
  uses = [ "cmake" ];
  # header-only
  phases.remove = [
    "cmake.build"
    "cmake.test"
  ];
}
