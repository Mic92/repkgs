# Zig from source. No prebuilt zig anywhere: the tarball's stage1/zig1.wasm is turned into C by
# the bundled wasm2c, cc compiles that to zig1, zig1 emits zig2.c, cc builds zig2, zig2 builds
# zig (stage3) against zig-llvm's libLLVM/libclang-cpp/lld.
{
  package,
  pkgs,
}:
package {
  name = "zig";
  uses = [ "cmake" ];
  cmake.defs = {
    ZIG_SHARED_LLVM = true;
    # a generic binary, not one tuned to (and hashed by) the build machine
    ZIG_TARGET_MCPU = "baseline";
    ZIG_PIE = true;
  };
  dependencies = [
    pkgs.zig-llvm
    pkgs.zlib
    pkgs.zstd
  ];
  # zig's own cache, else it writes to $HOME/.cache
  env.ZIG_GLOBAL_CACHE_DIR = "/build/zig-cache";
  tests.run = false; # `zig build test` is the multi-hour compiler suite
  tests.version = "version";
}
