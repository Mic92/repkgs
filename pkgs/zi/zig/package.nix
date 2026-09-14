# Zig from source. No prebuilt zig anywhere: the tarball's stage1/zig1.wasm is turned into C by
# the bundled wasm2c, cc compiles that to zig1, zig1 emits zig2.c, cc builds zig2, zig2 builds
# zig (stage3) against llvm21's libLLVM with clang21 and lld21.
{
  package,
  pkgs,
  buildPkgs,
  platform,
  on,
}:
let
  glibc = builtins.fromTOML (builtins.readFile ../../gl/glibc/sources.toml);
in
package {
  name = "zig";
  uses = [ "cmake" ];
  cmake.defs = {
    ZIG_SHARED_LLVM = true;
    # a generic binary, not one tuned to (and hashed by) the build machine
    ZIG_TARGET_MCPU = "baseline";
    ZIG_PIE = true;
    # Release would -Dstrip. stage3 is linked by zig's lld, not cc: ask for the build-id
    CMAKE_BUILD_TYPE = "RelWithDebInfo";
    ZIG_EXTRA_BUILD_ARGS = "--build-id=sha1";
  }
  # cross: zig2 would be a target binary, the build machine's zig builds stage3 instead. A target
  # triple turns llvm-config off (static LLVM by find_library): back on with the host's, by
  # search path since Findllvm.cmake unsets a given LLVM_CONFIG_EXE. That one comes out of
  # LLVM's NATIVE sub-configure, which probes no zlib/zstd, so --system-libs lacks them: zig's
  # own find_library adds them back
  // on platform.cross {
    ZIG_EXECUTABLE = "${buildPkgs.zig}/bin/zig";
    # our glibc's version: zig's default (2.28) stubs lack symbols our headers use (__isoc23_*)
    ZIG_TARGET_TRIPLE = "${platform.cpu}-linux-gnu.${glibc.pin.version}";
    ZIG_USE_LLVM_CONFIG = true;
    CMAKE_PROGRAM_PATH = "${pkgs.llvm21}/host";
    ZIG_STATIC_ZLIB = true;
    ZIG_STATIC_ZSTD = true;
  };
  patches = [ ./upstream-cmake-zig-executable.patch ];
  dependencies = [
    pkgs.llvm21
    pkgs.clang21
    pkgs.lld21
    pkgs.zlib
    pkgs.zstd
  ];
  # stage3 is linked by zig itself, not through cc: no padded RUNPATH, no crt_interp. Treated like
  # an upstream binary, formatelf implants both
  prebuilt = true;
  # zig's own cache (default $HOME/.cache). zig.nu saves and restores it through jigd
  env.ZIG_GLOBAL_CACHE_DIR = "/build/zig-cache";
  phases.after."cmake.configure" = "zig.restore";
  phases.after."cmake.build" = "zig.store";
  tests.run = false; # `zig build test` is the multi-hour compiler suite
  tests.version = "version";
}
