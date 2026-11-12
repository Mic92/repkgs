# jig: compiler driver and cache client. Built standalone for machines that run
# jigd outside the set (server-configuration's NixOS module); inside the set
# the bootstrap builds it instead (bootstrap.nu).
{
  package,
  pkgs,
}:
package {
  name = "jig";
  # unix socket cache client, ELF/Mach-O fixup
  platforms.posix = true;
  version = "1";
  source = ./src;
  uses = [ "make" ];
  dependencies = [
    pkgs.blake3
    pkgs.zstd
    pkgs.nlohmann-json
  ];
  # <json.hpp> as the Makefile wants it, not <nlohmann/json.hpp>
  cc.cxxflags = [
    "-isystem"
    "${pkgs.nlohmann-json}/include/nlohmann"
  ];
  make.flags = [
    "NIX_STORE_DIR=${builtins.storeDir}"
    # out of tree like the other build systems: $(...) expands from the build environment,
    # so outputs land in (ctx).build ($NIX_BUILD_TOP/build) and the source stays pristine.
    # A hand-run `make` uses the Makefile's own default, also outside the tree (/tmp)
    "BUILD=$(NIX_BUILD_TOP)/build"
    # the Makefile defaults to -O0 for iteration speed; the set ships optimized
    "OPT=-O3"
  ];
  make.testTarget = [ "test" ];
  # a driver: --version probes the compiler instead of printing one
  tests.version = false;
}
