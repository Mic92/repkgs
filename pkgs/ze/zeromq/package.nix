{
  package,
  pkgs,
  platform,
  on,
}:
package {
  name = "zeromq";
  uses = [ "cmake" ];
  patches = [
    ./upstream-nothrow-include-new.patch
    ./upstream-mingw-afunix.patch # aa885c5: afunix.h on all of windows, not just _MSC_VER
    ./upstream-curve-include-algorithm.patch
  ];
  cmake.defs = {
    CMAKE_POLICY_VERSION_MINIMUM = "3.5"; # cmake_minimum_required 2.8
    WITH_LIBSODIUM = true;
    ENABLE_CURVE = true;
  }
  # IPC (AF_UNIX) on windows needs the bundled wepoll, select cannot do it
  // on (platform.os == "windows") { POLLER = "epoll"; };
  dependencies = [ pkgs.libsodium ];
  cmake.skipTests = [ "test_mock_pub_sub" ]; # a hand-rolled TCP peer polls with msleep(1) against the 10 s TIMEOUT
  tests.parallel = false; # every test gets a 10 s TIMEOUT; in parallel on a loaded machine they exceed it
}
