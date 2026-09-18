{ package, platform }:
let
  # DYNAMIC_ARCH builds every kernel and picks one at run time, TARGET is only the fallback and
  # the baseline the common code is compiled for. getarch cannot probe a CPU it does not run on,
  # so cross builds have to name it
  target = {
    x86_64 = "HASWELL"; # x86-64-v3, our -march
    aarch64 = "ARMV8";
    riscv64 = "RISCV64_GENERIC";
    loongarch64 = "LOONGSONGENERIC";
    powerpc64le = "POWER8";
  };
in
package {
  name = "openblas";
  # The Makefile build runs getarch with HOSTCC, which is how every distribution cross-compiles
  # it. The CMake build instead fills in per-core parameters from a table in cmake/prebuild.cmake
  # that lags the Makefiles (no HAVE_SME for ARMV9SME, no -march=.._v for riscv64 in 0.3.34)
  uses = [ "make" ];
  make.flags = [
    "DYNAMIC_ARCH=1"
    "TARGET=${target.${platform.cpu}}"
    "HOSTCC=$(CC_FOR_BUILD)"
    "CROSS=${if platform.cross then "1" else "0"}"
    "NO_FORTRAN=1" # C LAPACK, no Fortran compiler
    "NUM_THREADS=64" # the default is the build machine's core count
    "USE_OPENMP=0" # Makefile.power alone defaults to OpenMP. pthreads like every other cpu
  ];
  make.buildTarget = [ "shared" ]; # the default goal also runs the tests
  make.testTarget = [ "tests" ]; # utest/ and ctest/
}
