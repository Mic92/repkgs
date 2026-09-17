{ package }:
package {
  name = "libusb";
  uses = [ "autotools" ];
  autotools.flags = [
    "--disable-udev" # no systemd yet
    "--enable-dependency-tracking" # the Windows .rc rule writes into .deps/ regardless
  ];
}
