{
  package,
  pkgs,
}:
package {
  name = "boost";
  uses = [ "cmake" ];
  # libc++ _LIBCPP_BEGIN_NAMESPACE_STD opens a clang attribute region
  # triggering unused attribute warnings spam in build log
  cc.cxxflags = [ "-Wno-pragma-clang-attribute" ];
  cmake.defs = {
    BOOST_ENABLE_MPI = false;
    BOOST_ENABLE_PYTHON = false;
  };
  patches = [
    ./upstream-redis-cmath.patch
    ./upstream-cobalt-mingw-libs.patch # 66b967a: -lmswsock -lbcrypt on mingw
  ];
  dependencies = [
    pkgs.zlib
    pkgs.bzip2
    pkgs.zstd
    pkgs.openssl
  ];
  tests.run = false; # hours
}
