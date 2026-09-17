{ package, pkgs }:
package {
  name = "zeromq";
  uses = [ "cmake" ];
  patches = [ ./upstream-nothrow-include-new.patch ];
  cmake.defs = {
    CMAKE_POLICY_VERSION_MINIMUM = "3.5"; # cmake_minimum_required 2.8
    WITH_LIBSODIUM = true;
    ENABLE_CURVE = true;
  };
  dependencies = [ pkgs.libsodium ];
  cmake.skipTests = [ "test_mock_pub_sub" ]; # a hand-rolled TCP peer polls with msleep(1) against the 10 s TIMEOUT
  tests.parallel = false; # every test gets a 10 s TIMEOUT; in parallel on a loaded machine they exceed it
}
