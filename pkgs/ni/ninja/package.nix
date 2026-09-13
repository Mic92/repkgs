{ package, platform }:
package {
  name = "ninja";
  phases = [ "ninja.build" ];
  install."bin/ninja${platform.exe}" = "../build/ninja${platform.exe}";
}
