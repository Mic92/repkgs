# mixed: cmake project importing a Rust staticlib through corrosion. cargo layer only for its setup
# (CARGO_HOME, offline config, remap flags), cmake drives the build
{ package, pkgs }:
package {
  name = "corrodemo";
  version = "0.1";
  source = ./src;
  uses = [
    "cmake"
    "cargo"
  ];
  steps = [
    "cmake.configure"
    "cmake.build"
    "cmake.test"
    "cmake.install"
  ];
  buildDependencies = [ pkgs.corrosion ];
  tests.version = false; # demo, prints no version
  bin = [ "corrodemo" ];
}
