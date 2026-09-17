{
  package,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "icu";
  uses = [ "autotools" ];
  autotools.root = "source";
  autotools.flags = [
    "--disable-icu-config"
  ]
  # icu.nu cross-buildroot makes that directory. /build is the sandbox's build dir on every Linux Nix
  ++ on platform.cross [ "--with-cross-build=/build/native-icu" ]
  # without it mh-darwin's install_name is a bare file name, which dyld looks up in the cwd
  ++ on (platform.os == "macos") [ "--enable-rpath" ];
  patches = [ ./upstream-ssearch-snprintf-bound.patch ]; # a test trips _FORTIFY_SOURCE=3
  phases.before."autotools.configure" = on platform.cross [ "icu.cross-buildroot" ];
  phases.after."autotools.install" = [ "icu.relative-prefix" ];
  buildDependencies = on platform.cross [ buildPkgs.icu ];
}
