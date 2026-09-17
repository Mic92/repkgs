{
  package,
  pkgs,
  platform,
  on,
}:
package {
  name = "hidapi";
  uses = [ "cmake" ];
  # backends: IOKit on macOS, hid.dll on Windows, libusb (and hidraw, no libudev yet) on Linux
  cmake.defs = on (platform.os == "linux") { HIDAPI_WITH_HIDRAW = false; };
  dependencies = on (platform.os == "linux") [ pkgs.libusb ];
}
