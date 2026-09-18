# LLVM's OpenMP host runtime: libomp and omp.h for -fopenmp. Not part of `cc` so packages opt in.
# Its ABI to the compiler (__kmpc_*, GOMP_*) only grows, so the pin need not match the toolchain
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
      LIBOMP_OMPD_SUPPORT = false; # the debugger plugin wants libpython
      LIBOMP_INSTALL_ALIASES = false; # no libgomp.so/libiomp5.so symlinks until something asks
      OPENMP_ENABLE_OMPT_TOOLS = false; # libarcher, a TSan annotation tool
      OPENMP_ENABLE_TESTING = false;
    };
    buildDependencies = [ buildPkgs.cpython ]; # message catalog and .def generators
    tests.run = false; # lit suite against FileCheck
  }
  # kmp_wrapper_getpid.h typedefs pid_t when the driver is cl-style, not when the target is msvc
  // on (platform.libc == "msvc") { cc.cflags = [ "-Dpid_t=int" ]; }
  # x86 Windows assembles z_Windows_NT-586_asm.asm with MASM. llvm-ml joins cc at its next rebuild
  // on (platform.cpu == "x86_64") {
    platforms.os = [
      "linux"
      "macos"
    ];
  }
)
