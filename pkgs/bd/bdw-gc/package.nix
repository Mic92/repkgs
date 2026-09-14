{ package }:
package {
  name = "bdw-gc";
  uses = [ "cmake" ];
  cmake.defs = {
    enable_cplusplus = true; # nix
    enable_large_config = true;
    enable_mmap = true;
    enable_docs = false;
  };
  # nix evaluations overflow the default mark stack
  cc.cflags = [ "-DINITIAL_MARK_STACK_SIZE=1048576" ];
}
