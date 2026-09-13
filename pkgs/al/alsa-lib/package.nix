{ package }:
package {
  name = "alsa-lib";
  uses = [ "autotools" ];
  # plugins are the system's
  patches = [ ./relocatable.patch ];
  autotools.flags = [
    "--with-plugindir=/usr/lib/alsa-lib"
    "--disable-python"
    "--disable-topology"
  ];
}
