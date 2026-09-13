{
  package,
  pkgs,
  buildPkgs,
  platform,
}:
package {
  name = "nix";
  uses = [ "meson" ];
  meson.defs = {
    unit-tests = false;
    functional-tests = false;
    json-schema-checks = false;
    doc-gen = false;
  }
  // (if platform.cpu == "x86_64" then { "libutil:cpuid" = "enabled"; } else { })
  // (if platform.os == "linux" then { "libstore:seccomp-sandboxing" = "enabled"; } else { });
  dependencies = [
    pkgs.bzip2
    pkgs.curl
    pkgs.libarchive
    pkgs.openssl
    pkgs.sqlite
    pkgs.xz
    pkgs.zlib
    pkgs.zstd
    pkgs.blake3
    pkgs.boost
    pkgs.libsodium
    pkgs.brotli
    pkgs.nlohmann-json
    pkgs.libgit2
    pkgs.toml11
    pkgs.editline
  ]
  ++ (if platform.cpu == "x86_64" then [ pkgs.libcpuid ] else [ ])
  ++ (if platform.os == "linux" then [ pkgs.libseccomp ] else [ ]);
  # Missing dependencies to be added one by one:
  # pkgs.bdw-gc
  # pkgs.lowdown
  buildDependencies = [
    buildPkgs.bison
    buildPkgs.cmake
    buildPkgs.flex
    buildPkgs.jq
  ];
  patches = [ ./clang23-nodiscard.patch ];
  tests.run = false;
}
