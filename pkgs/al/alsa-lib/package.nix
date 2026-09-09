{ package }:
package {
  name = "alsa-lib";
  uses = [ "autotools" ];
  # plugins are the system's. alsa.conf ships in $out/share/alsa, found relative to libasound
  # only if ALSA_CONFIG_DIR says so: applications playing sound set it or use the system's
  autotools.flags = [
    "--with-plugindir=/usr/lib/alsa-lib"
    "--disable-python"
    "--disable-topology"
  ];
}
