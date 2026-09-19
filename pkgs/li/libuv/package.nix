{
  package,
  buildPkgs,
  platform,
  lib,
}:
package {
  name = "libuv";
  uses = [ "cmake" ];
  cmake.tool = buildPkgs.cmake-bootstrap; # cmake links this
  cmake.defs = {
    LIBUV_BUILD_TESTS = false;
  };
  # static libuv.lib beside the DLL's uv.lib: FindLibUV picks it and nobody links its userenv/ws2_32
  phases.after."cmake.install" = lib.on (platform.abi == "msvc") [
    {
      name = "shared-only";
      run = ''rm $"($c.out)/lib/libuv.lib" $"($c.out)/lib/pkgconfig/libuv-static.pc"'';
    }
  ];
}
