{ package, platform }:
package {
  name = "ninja";
  phases = [ "ninja.build" ];
  install."bin/ninja${platform.ext.exe}" = "../build/ninja${platform.ext.exe}";
}
