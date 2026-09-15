# the nongnu libunwind (unw_* over ptrace and core dumps), not LLVM's unwinder
{ package, pkgs }:
package {
  name = "libunwind";
  uses = [ "autotools" ];
  patches = [ ./upstream-test-runner-relative.patch ];
  autotools.outOfTree = false; # tests/run-ptrace-* look for test-ptrace next to themselves
  dependencies = [
    pkgs.xz
    pkgs.zlib
  ];
  platforms.os = [ "linux" ];
}
