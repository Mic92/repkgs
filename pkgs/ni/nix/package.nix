{
  package,
  pkgs,
  buildPkgs,
  platform,
  on,
}:
package {
  name = "nix";
  uses = [ "meson" ];
  meson.defs = {
    unit-tests = false;
    functional-tests = false;
    json-schema-checks = false;
    doc-gen = false;
    "nix:mimalloc" = "enabled";
  }
  // on (platform.cpu == "x86_64") { "libutil:cpuid" = "enabled"; }
  // on (platform.os == "linux") { "libstore:seccomp-sandboxing" = "enabled"; };
  dependencies = [
    pkgs.bzip2
    pkgs.curl
    pkgs.libarchive
    pkgs.openssl
    pkgs.sqlite
    pkgs.xz
    pkgs.zlib
    pkgs.zstd
    pkgs.bdw-gc
    pkgs.blake3
    pkgs.boost
    pkgs.libsodium
    pkgs.lowdown
    pkgs.brotli
    pkgs.nlohmann-json
    pkgs.libgit2
    pkgs.toml11
    pkgs.editline
    pkgs.mimalloc
  ]
  ++ on (platform.cpu == "x86_64") [ pkgs.libcpuid ]
  ++ on (platform.os == "linux") [ pkgs.libseccomp ];
  buildDependencies = [
    buildPkgs.bison
    buildPkgs.cmake
    buildPkgs.flex
  ];
  phases.before."meson.configure" = {
    name = "version";
    run = ''$c.spec.version | save -f $"($c.src)/.version"'';
  };
  patches = [
    ./relocatable.patch
    ./upstream-undef-embedded-sandbox-shell.patch
  ];
  tests.run = false;
}
