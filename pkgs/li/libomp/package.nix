# LLVM's OpenMP host runtime (libomp.so, omp.h) for packages built with -fopenmp. A separate
# package rather than part of `cc`. The compiler-facing ABI (__kmpc_*, GOMP_*) is append-only,
# so this pin may differ from the toolchain's LLVM version
{
  package,
  buildPkgs,
  platform,
  on,
}:
package (
  {
    name = "libomp";
    uses = [ "cmake" ];
    cmake.root = "runtimes";
    cmake.defs = {
      LLVM_ENABLE_RUNTIMES = "openmp";
      LLVM_INCLUDE_TESTS = false;
      OPENMP_ENABLE_LIBOMPTARGET = false; # no device offload
      LIBOMP_OMPD_SUPPORT = false; # debugger plugin, needs libpython
      LIBOMP_INSTALL_ALIASES = false; # libgomp.so/libiomp5.so compatibility symlinks
      OPENMP_ENABLE_OMPT_TOOLS = false; # libarcher (TSan annotations)
      OPENMP_ENABLE_TESTING = false;
    };
    buildDependencies = [ buildPkgs.cpython ]; # generates the message catalog and .def files
    tests.run = false; # the tests need lit and FileCheck
  }
  # kmp_wrapper_getpid.h only typedefs pid_t under a cl-style driver, ours is gcc-style on msvc too
  // on (platform.libc == "msvc") { cc.cflags = [ "-Dpid_t=int" ]; }
  # not on x86_64 Windows yet: z_Windows_NT-586_asm.asm needs MASM (llvm-ml, added to cc separately)
  // on (platform.cpu == "x86_64") {
    platforms.os = [
      "linux"
      "macos"
    ];
  }
)
