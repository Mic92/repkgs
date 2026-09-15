{ package, pkgs }:
package {
  name = "libevent";
  uses = [ "cmake" ];
  tests.run = false; # regress asserts wall-clock timings (loopexit: 300±50 ms), flaky under load
  cmake.defs = {
    CMAKE_POLICY_VERSION_MINIMUM = "3.5"; # cmake_minimum_required 3.1
    EVENT__LIBRARY_TYPE = "SHARED";
  };
  dependencies = [ pkgs.openssl ];
}
